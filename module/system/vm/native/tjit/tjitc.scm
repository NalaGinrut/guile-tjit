;;;; Entry point for compiler used in vm-tjit engine

;;;; Copyright (C) 2014, 2015 Free Software Foundation, Inc.
;;;;
;;;; This library is free software; you can redistribute it and/or
;;;; modify it under the terms of the GNU Lesser General Public
;;;; License as published by the Free Software Foundation; either
;;;; version 3 of the License, or (at your option) any later version.
;;;;
;;;; This library is distributed in the hope that it will be useful,
;;;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;;;; Lesser General Public License for more details.
;;;;
;;;; You should have received a copy of the GNU Lesser General Public
;;;; License along with this library; if not, write to the Free Software
;;;; Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA
;;;; 02110-1301 USA
;;;;

;;; Commentary:
;;;
;;; Module exporting @code{tjitc}, entry point of just-in-time compiler for
;;; `vm-tjit' engine. The procedure @code{tjitc} is called from C code in
;;; "libguile/vm-tjit.c".
;;;
;;; Code:

(define-module (system vm native tjit tjitc)
  #:use-module (ice-9 format)
  #:use-module (ice-9 match)

  ;; Workaround for avoiding segfault while fresh auto compile. Without the
  ;; import of (language scheme spec) module, fresh auto compilation with no
  ;; `--tjit-dump' option was showing segfault.
  #:use-module (language scheme spec)

  #:use-module ((srfi srfi-1) #:select (last))
  #:use-module (srfi srfi-11)
  #:use-module (system vm native debug)
  #:use-module (system vm native tjit compile-ir)
  #:use-module (system vm native tjit compile-native)
  #:use-module (system vm native tjit dump)
  #:use-module (system vm native tjit env)
  #:use-module (system vm native tjit error)
  #:use-module (system vm native tjit fragment)
  #:use-module (system vm native tjit parameters)
  #:use-module (system vm native tjit parse)
  #:use-module (system vm native tjit snapshot)
  #:export (tjitc init-vm-tjit)
  #:re-export (tjit-stats))


;;;
;;; Entry point
;;;

(define (tjitc trace-id bytecode traces parent-ip parent-exit-id linked-ip
               loop? downrec? uprec?)
  (when (tjit-dump-time? (tjit-dump-option))
    (let ((log (make-tjit-time-log (get-internal-run-time) 0 0 0 0 0)))
      (put-tjit-time-log! trace-id log)))
  (let* ((parent-fragment (get-fragment parent-ip))
         (parent-snapshot (if parent-fragment
                              (hashq-ref (fragment-snapshots parent-fragment)
                                         parent-exit-id)
                              #f))
         (entry-ip (car (last traces)))
         (dump-option (tjit-dump-option))
         (sline (addr->source-line entry-ip))
         (env
          (call-with-values
              (lambda ()
                (match parent-snapshot
                  (($ $snapshot id sp fp nlocals locals variables code ip lives
                      depth)
                   (values sp fp (map car locals) lives locals depth))
                  (_
                   (values 0 0 '() '() '() 0))))
            (lambda args
              (apply make-env trace-id entry-ip linked-ip
                     parent-exit-id parent-fragment parent-snapshot
                     loop? downrec? uprec? args)))))
    (define (show-sline)
      (let ((exit-pair (if (< 0 parent-ip)
                           (format #f " (~a:~a)"
                                   (or (and=> parent-fragment fragment-id)
                                       (format #f "~x" parent-ip))
                                   parent-exit-id)
                           ""))
            (linked-id (if parent-snapshot
                           (format #f " -> ~a"
                                   (and=> (env-linked-fragment env)
                                          fragment-id))
                           ""))
            (ttype (cond
                    (downrec? " - downrec")
                    (uprec? " - uprec")
                    (else ""))))
        (format #t ";;; trace ~a: ~a:~a~a~a~a~%"
                trace-id (car sline) (cdr sline) exit-pair linked-id ttype)))
    (define-syntax dump
      (syntax-rules ()
        ((_ test data exp)
         (when (and (test dump-option)
                    (or data (tjit-dump-abort? dump-option)))
           exp))))
    (define (failure msg)
      (debug 2 ";;; trace ~a: ~a~%" trace-id msg)
      (tjit-increment-compilation-failure! entry-ip))
    (define (compile-traces traces)
      (let-values (((snapshots anf ops) (compile-ir env traces)))
        (dump tjit-dump-anf? anf (dump-anf trace-id anf))
        (dump tjit-dump-ops? ops (dump-primops trace-id ops snapshots))
        (let-values (((code size adjust loop-address trampoline)
                      (compile-native env ops snapshots sline)))
          (tjit-increment-id!)
          (dump tjit-dump-ncode? code
                (dump-ncode trace-id entry-ip code size adjust
                            loop-address snapshots trampoline
                            (not parent-snapshot))))
        (when (tjit-dump-time? dump-option)
          (let ((log (get-tjit-time-log trace-id))
                (t (get-internal-run-time)))
            (set-tjit-time-log-end! log t)))))

    (with-tjitc-error-handler entry-ip
      (let-values (((traces implemented?) (parse-bytecode env bytecode traces)))
        (dump tjit-dump-jitc? implemented? (show-sline))
        (dump tjit-dump-bytecode? implemented? (dump-bytecode trace-id traces))
        (cond
         ((not env)
          (failure "error during parse"))
         ((not implemented?)
          (failure "NYI - unimplemented bytecode"))
         (uprec?
          (failure "NYI - up recursion"))
         (downrec?
          (failure "NYI - down recursion"))
         ((and (not parent-snapshot) (not loop?))
          (failure "NYI - loop-less root trace"))
         ((and (not parent-snapshot) (not (zero? (env-sp-offset env))))
          (failure "NYI - looping root trace with stack pointer shift"))
         ((and parent-snapshot (not (env-linked-fragment env)))
          (failure "NYI - type mismatch in linked fragment"))
         (else
          (with-nyi-handler entry-ip (compile-traces traces))))))))


;;;
;;; Initialization
;;;

(define (init-vm-tjit interactive?)
  "Dummy procedure for @code{autoload}."
  ((@ (system vm native lightning) init-jit) "")
  #t)

;; Call `load-extension' from top-level after defining `tjitc',
;; "scm_bootstrap_vm_tjit" will lookup `tjitc' variable and assign to C
;; variable.
(load-extension (string-append "libguile-" (effective-version))
                "scm_bootstrap_vm_tjit")
