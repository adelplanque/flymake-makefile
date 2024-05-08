Presentation
============

Provides flymake backends for makefile files.

There are currently 2 backends:

* make: make is called on a dummy target
* checkmake: [checkmake](https://github.com/mrtazz/checkmake) is a makefile linter


Admonition
==========

Be careful, make backend can lead to a security risk, as the execution of
untrusted makefiles can lead to the execution of malicious code, and is disable
by default.

To enable it you must set `flymake-makefile-use-make-backend' to t. This can be
done per directory:

```lisp
;;; .dir-locals.el
((makefile-mode . ((flymake-makefile-use-make-backend . t))))
```

By default the make command is run in a firejail sandbox, restricting read-only
access to the user's directory.  Firejail can be installed from most Linux
distributions.

```make
# Executing this Makefile will have no side effect
my-var := $(shell echo attack > attack)
target:
    some-action
```

Usage
=====

```lisp
(require 'flymake-makefile)
(add-hook 'makefile-mode-hook #'flymake-makefile-mode-hook)
```
