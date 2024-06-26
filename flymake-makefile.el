;;; flymake-makefile.el --- Flymake backends for makefile -*- lexical-binding: t -*-

;; Copyright (C) 2024 Alain Delplanque

;; Maintainer: Alain Delplanque <alaindelplanque@mailoo.org>
;; Author: Alain Delplanque <alaindelplanque@mailoo.org>
;; Version: 0.1
;; Package-Requires: ((emacs "27.1"))
;; Keywords: tools, flymake
;; URL: https://github.com/adelplanque/flymake-makefile

;; This file is NOT part of GNU Emacs.

;;; Licence:

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; Provides flymake backends for makefile files.

;; * make: Invoque make command with a dummy target
;; * checkmake: checkmake is an experimental tool for linting and checking
;;   Makefiles, for more details see:
;;       https://github.com/mrtazz/checkmake

;; Admonition:

;; Be careful, make backend can lead to a security risk, as the execution of
;; untrusted makefiles can lead to the execution of malicious code, and is
;; disable by default.

;; To enable it you must set `flymake-makefile-use-make-backend' to t. This can
;; be done per directory:

;;     ;;; .dir-locals.el
;;     ((makefile-mode . ((flymake-makefile-use-make-backend . t))))

;; By default the make command is run in a firejail sandbox, restricting
;; read-only access to the user's directory.  Firejail can be installed from
;; most Linux distributions.

;;     # Executing this Makefile will have no side effect
;;     my-var := $(shell echo attack > attack)
;;     target:
;;         some-action

;; Usage:

;;     (require 'flymake-makefile)
;;     (add-hook 'makefile-mode-hook #'flymake-makefile-mode-hook)

;;; Code:

(eval-when-compile (require 'cl-lib))
(require 'flymake)

(defgroup flymake-makefile nil
  "Flymake backend for makefile files."
  :group 'flymake)

(defcustom flymake-makefile-make-executable (executable-find "make")
  "Name of the ‘make’ executable."
  :group 'flymake-makefile
  :type 'string)

(defcustom flymake-makefile-checkmake-executable (executable-find "checkmake")
  "Name of the ‘checkmake’ executable."
  :group 'flymake-executable
  :type 'string)

(defcustom flymake-makefile-firejail-executable (executable-find "firejail")
  "Name of the ‘firejail’ executable."
  :group 'flymake-executable
  :type 'string)

(defcustom flymake-makefile-use-make-backend nil
  "Should the make command be used as a flymake backend.
Be aware that enabling this backend will execute make on the makefile, this can
cause in strong side effect, especially enabling it on an untrusted makefile can
be a security issue."
  :group 'flymake-makefile
  :type 'bool)

(defcustom flymake-makefile-use-firejail t
  "Should the make command be sandboxed with Firejail ?
By default, the make command is run with restricted permission (read-only HOME
file system) using Firejail."
  :group 'flymake-makefile
  :type 'string)

(defcustom flymake-makefile-use-checkmake-backend t
  "Should the checkmake command be used as a flymake backend."
  :group 'flymake-makefile
  :type 'bool)

(defvar-local flymake-makefile--make-proc nil
  "Current make process running in this buffer.")

(defvar-local flymake-makefile--checkmake-proc nil
  "Current checkmake process running in this buffer.")

(defvar-local flymake-makefile--make-temp-filename nil
  "Current temporary filename use to write buffer for make.")

(defvar-local flymake-makefile--checkmake-temp-filename nil
  "Current temporary filename use to write buffer for checkmake.")

(defconst flymake-makefile--checkmake-rules-alist
  '(("maxbodylength" . :note)
    ("minphony" . :warning)
    ("phonydeclared" . :warning)
    ("timestampexpanded" . :warning))
  "An alist associating checkmake rule with error level.")

(defun flymake-makefile--create-temp-copy (var-name suffix)
  "Store content of buffer to a file.
Temporary file name is creating by appending SUFFIX to the buffer file name, and
store in the symbol VAR-NAME."
  (set var-name (concat buffer-file-name suffix))
  (flymake-log :debug "save buffer to temporary file %s" (symbol-value var-name))
  (flymake-proc--save-buffer-in-file (symbol-value var-name)))

(defun flymake-makefile--safe-delete-file (file-name)
  "Deletes the file FILE-NAME ensuring its prior existence."
  (when (and file-name (file-exists-p file-name))
    (delete-file file-name)
    (flymake-log :debug "deleted file %s" file-name)))

(defun flymake-makefile--make-report (report-fn buf proc)
  "Create flymake diagnostics related to the output of the make process.
BUF designates the buffer when launching the PROC process, diagnostics are then
reported by calling REPORT-FN."
  (when (memq (process-status proc) '(exit signal))
    (unwind-protect
        (if (with-current-buffer buf (eq proc flymake-makefile--make-proc))
            (with-current-buffer (process-buffer proc)
              (goto-char (point-min))
              (cl-loop
               while (re-search-forward
                      "^\\([[:alnum:]/_.-]*\\):\\([0-9]*\\):[[:blank:]]*\\(.*\\)$"
                      nil t)
               for keep = (equal (with-current-buffer buf flymake-makefile--make-temp-filename)
                                 (expand-file-name (match-string 1)))
               when keep
               for (beg . end) = (flymake-diag-region buf (string-to-number (match-string 2)))
               when keep
               collect (flymake-make-diagnostic buf beg end :error (match-string 3))
               into diags
               finally (funcall report-fn diags)))
          (flymake-log :warning "Canceling obsolete check %s" proc))
      (kill-buffer (process-buffer proc))
      (flymake-makefile--safe-delete-file flymake-makefile--make-temp-filename))))

(defun flymake-makefile--backend-make (report-fn &rest _args)
  "Flymake backend using make program.
Works by invoking make with a dummy target to detect syntax errors.
Takes a Flymake callback REPORT-FN as argument."
  (when flymake-makefile-use-firejail
    (unless flymake-makefile-firejail-executable (error "Cannot find firejail executable")))
  (when (process-live-p flymake-makefile--make-proc)
    (kill-process flymake-makefile--make-proc))
  (unless flymake-makefile-make-executable (error "Cannot find make executable"))
  (flymake-makefile--create-temp-copy 'flymake-makefile--make-temp-filename "_make_flymake")
  (save-excursion
    (widen)
    (setq flymake-makefile--make-proc
          (make-process
           :name "make"
           :buffer (generate-new-buffer " *flymake-makefile*")
           :command (append (when flymake-makefile-use-firejail
                              `("firejail" "--quiet" "--noprofile" "--caps.drop=all" "--seccomp"
                                "--noroot" ,(concat "--read-only=" (expand-file-name "~"))))
                            `(,flymake-makefile-make-executable
                              "-f" ,flymake-makefile--make-temp-filename
                              "dummy-flymake-target"))
           :sentinel (lambda (proc _event)
                       (flymake-makefile--make-report report-fn (current-buffer) proc))))))

(defun flymake-makefile--checkmake-report (report-fn buf proc)
  "Create flymake diagnostics related to the output of the checkmake process.
BUF designates the buffer when launching the PROC process, diagnostics are then
reported by calling REPORT-FN."
  (when (memq (process-status proc) '(exit signal))
    (unwind-protect
        (if (with-current-buffer buf (eq proc flymake-makefile--checkmake-proc))
            (with-current-buffer (process-buffer proc)
              (goto-char (point-min))
              (cl-loop
               while (re-search-forward
                      "^\\([0-9]+\\):\\([[:alnum:]]*\\):\\(.*\\)$"
                      nil t)
               for (beg . end) = (flymake-diag-region buf (string-to-number (match-string 1)))
               collect (flymake-make-diagnostic
                        buf beg end
                        (or (cdr (assoc (match-string 2) flymake-makefile--checkmake-rules-alist))
                            :warning)
                        (concat (match-string 2) ": " (match-string 3)))
               into diags
               finally (funcall report-fn diags)))
          (flymake-log :warning "Canceling obsolete check %s" proc))
      (kill-buffer (process-buffer proc))
      (flymake-makefile--safe-delete-file flymake-makefile--checkmake-temp-filename))))

(defun flymake-makefile--backend-checkmake (report-fn &rest _args)
  "Flymake backend using checkmake program.
Takes a Flymake callback REPORT-FN as argument."
  (when (process-live-p flymake-makefile--checkmake-proc)
    (kill-process flymake-makefile--checkmake-proc))
  (unless flymake-makefile-checkmake-executable (error "Cannot find make executable"))
  (flymake-makefile--create-temp-copy 'flymake-makefile--checkmake-temp-filename
                                      "_checkmake_flymake")
  (save-restriction
    (widen)
    (setq flymake-makefile--checkmake-proc
          (make-process
           :name "checkmake"
           :buffer (generate-new-buffer " *flymake-makefile-checkmake*")
           :command `(,flymake-makefile-checkmake-executable
                      "--format={{.LineNumber}}:{{.Rule}}:{{.Violation}}{{\"\\n\"}}"
                      ,flymake-makefile--checkmake-temp-filename)
           :sentinel (lambda (proc _event)
                       (flymake-makefile--checkmake-report report-fn (current-buffer) proc))))))

;;;###autoload
(defun flymake-makefile-setup ()
  "Add the backends into Flymake's diagnostic functions list."
  (interactive)
  (if flymake-makefile-use-make-backend
      (add-hook 'flymake-diagnostic-functions #'flymake-makefile--backend-make nil t))
  (if flymake-makefile-use-checkmake-backend
      (add-hook 'flymake-diagnostic-functions #'flymake-makefile--backend-checkmake nil t)))

;;;###autoload
(defun flymake-makefile-mode-hook ()
  "Hook for `makefile-mode' to setup flymake backend.
Due to loading local variables after mode hooks, delegate the configuration as
`hack-local-variables-hook'.  This allows customize configuration by directories
using .dir-locals.el."
  (add-hook 'hack-local-variables-hook #'flymake-makefile-setup nil t))

(provide 'flymake-makefile)
;;; flymake-makefile.el ends here
