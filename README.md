Presentation
============

Provides flymake backends for makefile files.

There are currently 2 backends:

* make: make is called on a dummy target
* checkmake: [checkmake](https://github.com/mrtazz/checkmake) is a makefile linter


Usage
=====

```lisp
(require 'flymake-makefile)
(add-hook 'makefile-mode-hook #'flymake-makefile-setup)
```
