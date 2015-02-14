;;; -*- mode: scheme; coding: utf-8; -*-

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

;;; Intermediate representation of bytecode, for further assembling.

;;; Code:

(define-module (system vm basm)
  #:use-module (ice-9 match)
  #:use-module (language bytecode)
  #:use-module (srfi srfi-9)
  #:use-module (system foreign)
  #:use-module (system vm disassembler)
  #:use-module (system vm program)
  #:export (proc->basm
            make-basm basm? basm-ip basm-name basm-nargs basm-args
            basm-free-vars basm-chunks basm-labeled-ips
            basm-callees basm-callers basm-locals basm-prim-op?
            basm-chunks->alist basm->callees-list

            make-chunk chunk? chunk-labeled? chunk-dest-ip chunk-op

            make-call call? call-program call-args call-runtime-args
            call-node set-call-node!

            make-closure closure? closure-addr closure-free-vars

            *vm-op-sizes*))

(define-record-type <basm>
  (%make-basm name ip nargs args free-vars chunks labeled-ips
              callees callers locals prim-op?)
  basm?
  ;; Name of procedure.
  (name basm-name)
  ;; Bytecode instruction point.
  (ip basm-ip set-basm-ip!)
  ;; Number of arguments.
  (nargs basm-nargs)
  ;; Vector containing arguments.
  (args basm-args)
  ;; Vector containing free-vars.
  (free-vars basm-free-vars)
  ;; Hash table with key=ip, value=basm-chunk.
  (chunks basm-chunks)
  ;; List of ips referred as label destination.
  (labeled-ips basm-labeled-ips set-basm-labeled-ips!)
  ;; Hash table of callee procedures, key=program-code, value=<basm>.
  (callees basm-callees set-basm-callees!)
  ;; Hash table of caller, key=ip, value=program-code-addr.
  (callers basm-callers)
  ;; Local variables.
  (locals basm-locals set-basm-locals!)
  ;; Primitive procedure, or #f.
  (prim-op? basm-prim-op?))

(define* (make-basm name args free-vars prim-op? #:optional
                    (ip 0)
                    (chunks (make-hash-table))
                    (labeled-ips '())
                    (callees (make-hash-table))
                    (callers (make-hash-table))
                    (locals #f))
  (%make-basm name ip (vector-length args) args free-vars chunks
              labeled-ips callees callers locals prim-op?))

(define-record-type <chunk>
  (make-chunk dest-ip op)
  chunk?
  ;; Bytecode ip of destination, or #f.
  (dest-ip chunk-dest-ip)
  ;; Bytecode VM operation.
  (op chunk-op))

(define-record-type <closure>
  (make-closure addr free-vars)
  closure?
  (addr closure-addr)
  (free-vars closure-free-vars))

(define-record-type <call>
  (%make-call program args runtime-args node)
  call?
  (program call-program)
  (args call-args)
  (runtime-args call-runtime-args set-call-runtime-args!)
  (node call-node set-call-node!))

(define (make-call program args)
  (%make-call program args #f #f))

(define runtime-call (make-call 0 (vector)))

;; (define-record-type <runtime-obj>
;;   (make-runtime-obj op)
;;   runtime-obj?
;;   (op runtime-obj-op))

(define (basm-chunks->alist chunks)
  (sort (hash-fold (lambda (k v acc) (cons (cons k v) acc))
                   '()
                   chunks)
        (lambda (a b) (< (car a) (car b)))))

;; (define (basm->callees-list basm)
;;   (define (lp basm)
;;     (if (basm? basm)
;;         (hash-fold (lambda (k v acc)
;;                      (cons (cons k v) (append (lp v) acc)))
;;                    '()
;;                    (basm-callees basm))
;;         '()))
;;   (reverse (lp basm)))

(define (basm->callees-list basm)
  (define (lp seen basm)
    (if (basm? basm)
        (hash-fold
         (lambda (k v acc)
           (cond ((hashq-ref seen k)
                  acc)
                 (else
                  (hashq-set! seen k #t)
                  (cons (cons k v) (append (lp seen v) acc)))))
         '()
         (basm-callees basm))
        '()))
  (reverse (lp (make-hash-table) basm)))

;; Hash table containing sizes of bytecode, in byte.
(define *vm-op-sizes* (make-hash-table))

(for-each
 (lambda (op)
   (let ((name (car op))
         (size (- (length op) 3)))
     (hashq-set! *vm-op-sizes* name size)))
 (instruction-list))

(define (dereference-scm pointer)
  (pointer->scm (dereference-pointer pointer)))

;; XXX: Refer C code.
(define struct-procedure-index 1)

(define (ensure-program-addr program-or-addr)
  (or (and (program? program-or-addr)
           (program-code program-or-addr))
      (and (struct? program-or-addr)
           (let ((ref (struct-ref program-or-addr struct-procedure-index)))
             (and (program? ref)
                  (program-code ref))))
      program-or-addr))

(define (proc->basm program-or-addr args)
  ;; (format #t ";;; proc->basm:~%;;;   program-or-addr=~a~%;;;   args=~a~%"
  ;;         program-or-addr args)
  (proc->basm* (make-hash-table)
               (ensure-program-addr program-or-addr)
               args))

(define (proc->basm* seen program-or-addr args)
  (define (f op basm)
    (define (base-ip)
      (if (program? program-or-addr)
          (program-code program-or-addr)
          program-or-addr))
    (define (local-ref n)
      (vector-ref (basm-locals basm) n))
    (define (local-set! idx val)
      (vector-set! (basm-locals basm) idx val))
    (define (offset->addr offset)
      (+ (base-ip) (* 4 (+ (basm-ip basm) offset))))
    (define (locals->args proc-local nlocals)
      (let ((args (make-vector nlocals)))
        (let lp ((n 0))
          (if (< n nlocals)
              (begin
                (vector-set! args n (local-ref (+ n proc-local)))
                (lp (+ n 1)))
              args))))
    (define (set-caller! proc)
      (let ((addr (ensure-program-addr proc)))
        ;; Storing proc itself. Variables for primitive procedures may use same
        ;; address for different procedures.
        (hashq-set! (basm-callers basm) (basm-ip basm) proc)))
    (define (set-callee! proc proc-local nlocals)
      (cond
       ((closure? proc)
        (hashq-set! seen (closure-addr proc) #t)
        (let ((callee (proc->basm* seen
                                   (closure-addr proc)
                                   (locals->args proc-local nlocals))))
          ;; (set-basm-callees! basm (basm-callees callee))
          ;; (hash-for-each (lambda (k v)
          ;;                  ;; (hashq-set! (basm-callees basm) k v)
          ;;                  (format #t "basm-callees callee: ~a => ~a~%"
          ;;                          k (basm-name v)))
          ;;                (basm-callees callee))
          (hashq-set! (basm-callees basm) (closure-addr proc) callee)
          (hashq-set! (basm-callees basm)
                      (append (list 'closure (basm-ip basm)
                                    (map (lambda (n)
                                           (+ n proc-local))
                                         (iota nlocals))))
                      proc)))

       ((call? proc)
        ;; (hashq-set! seen (ensure-program-addr (call-program proc)) #t)
        (set-call-runtime-args! proc (locals->args proc-local nlocals))
        (hashq-set! (basm-callees basm)
                    (append (list 'call (basm-ip basm))
                            (map (lambda (n)
                                   (+ n proc-local))
                                 (iota nlocals)))
                    proc))

       ((unspecified? proc)
        *unspecified*)

       ;; XXX: Need to handle smob and structs, as done in vm-engine's
       ;; `apply:'.
       ((not (hashq-ref seen (ensure-program-addr proc)))
        (hashq-set! seen (ensure-program-addr proc) #t)
        (let ((callee (proc->basm* seen proc (locals->args proc-local nlocals))))
          ;; (set-basm-callees! basm (basm-callees callee))
          ;; (hash-for-each (lambda (k v)
          ;;                  ;; (hashq-set! (basm-callees basm) k v)
          ;;                  (format #t "basm-callees callee: ~a => ~a~%"
          ;;                          k (basm-name v))
          ;;                  )
          ;;                (basm-callees callee))
          (hashq-set! (basm-callees basm)
                      (ensure-program-addr proc)
                      callee)))))
    (define (set-caller/callee! proc proc-local nlocals)
      (set-callee! proc proc-local nlocals)
      (set-caller! proc))

    ;; Resolve label destinations.
    (let ((dst #f))
      ;; (format #t "(~a) ~3d: ~a~%" program-or-addr (basm-ip basm) op)
      (case (car op)
        ((br
          br-if-nargs-ne br-if-nargs-lt br-if-nargs-gt br-if-npos-gt
          br-if-true br-if-null br-if-nil br-if-pair br-if-struct br-if-char
          br-if-tc7
          br-if-eq br-if-eqv br-if-equal
          br-if-= br-if-< br-if-<= br-if-logtest)
         (let ((dest (+ (basm-ip basm) (list-ref op (- (length op) 1)))))
           (set-basm-labeled-ips! basm (cons dest (basm-labeled-ips basm)))
           (set! dst dest))))
      (hashq-set! (basm-chunks basm) (basm-ip basm) (make-chunk dst op)))

    ;; Resolve callers and callees with locals variables.
    (match op

      ;; Call and return
      (('call proc nlocals)
       (set-caller/callee! (local-ref proc) proc nlocals)
       (local-set! (+ proc 1) (make-call (local-ref proc)
                                         (locals->args proc nlocals))))
      (('tail-call nlocals)
       (set-caller/callee! (local-ref 0) 0 nlocals)
       (local-set! 1 (make-call 0 (locals->args 0 nlocals))))
      (('call-label proc nlocals target)
       (set-caller/callee! (offset->addr target) proc nlocals)
       (local-set! (+ proc 1) (make-call (local-ref proc)
                                         (locals->args proc nlocals))))
      (('tail-call-label nlocals target)
       (set-caller/callee! (offset->addr target) 0 nlocals)
       (local-set! 1 (make-call 0 (locals->args 0 nlocals))))
      (('receive dst proc nlocals)
       (local-set! dst (local-ref (+ proc 1))))

      ;; Function prologues
      (('assert-nargs-ee/locals expected nlocals)
       (let ((locals (make-vector (+ expected nlocals) *unspecified*)))
         ;; (when (not (= expected (vector-length args)))
         ;;   ;; (error "assert-nargs-ee/locals: argument length mismatch"
         ;;   ;;        (basm-ip basm) expected args)
         ;;   (format #t "assert-nargs-ee/locals: ~a~%" program-or-addr)
         ;;   (format #t "  expected ~a, args ~a~%" expected args))
         (let lp ((n 0))
           (when (and (< n expected)
                      (< n (vector-length args)))
             (vector-set! locals n (vector-ref args n))
             (lp (+ n 1))))
         (set-basm-locals! basm locals)))

      ;; Lexical binding instructions
      (('mov dst src)
       (local-set! dst (local-ref src)))
      (('box dst src)
       (local-set! dst (make-variable src)))
      (('box-ref dst src)
       (local-set! dst (variable-ref (local-ref src))))
      (('box-set dst src)
       (variable-set! (local-ref dst) (local-ref src)))
      (('make-closure dst offset nfree)
       ;; (set-callee! (offset->addr offset) 0 0)
       (local-set! dst (make-closure (offset->addr offset)
                                     (make-vector nfree))))
      (('free-set! dst src idx)
       ;; (local-set! dst runtime-call)
       (let ((p (local-ref dst)))
         (cond ((program? p)
                (program-free-variable-set! p idx (local-ref src)))
               ((closure? p)
                (vector-set! (closure-free-vars p) idx (local-ref src)))
               (else
                (local-set! dst runtime-call)))))
      (('free-ref dst src idx)
       ;; (local-set! dst runtime-call)
       (let ((p (local-ref src)))
         (cond ((and (program? p)
                     (< idx (program-num-free-variables p)))
                (local-set! dst (program-free-variable-ref p idx)))
               ((closure? p)
                (local-set! dst (vector-ref (closure-free-vars p) idx)))
               (else
                ;; (local-set! dst *unspecified*)
                (local-set! dst runtime-call)))))

      ;; Immediates and staticaly allocated non-immediates
      (('make-non-immediate dst target)
       (local-set! dst (pointer->scm (make-pointer (offset->addr target)))))

      ;; Mutable top-level bindings
      (('toplevel-box dst var-offset mod-offset sym-offset bound?)
       (let* ((current (basm-ip basm))
              (offset->pointer
               (lambda (offset) (make-pointer (offset->addr offset))))
              (var (dereference-scm (offset->pointer var-offset))))
         (if (variable? var)
             (local-set! dst var)
             (let ((resolved (module-variable
                              (dereference-scm
                               (offset->pointer mod-offset))
                              (dereference-scm
                               (offset->pointer sym-offset)))))
               (local-set! dst resolved)))))
      (('module-box dst var-offset mod-offset sym-offset bound?)
       (let* ((current (basm-ip basm))
              (offset->pointer
               (lambda (offset) (make-pointer (offset->addr offset))))
              (var (dereference-scm (offset->pointer var-offset))))
         (if (variable? var)
             (local-set! dst var)
             (let ((resolved (module-variable
                              (resolve-module
                               (cdr (pointer->scm
                                     (offset->pointer mod-offset))))
                              (dereference-scm
                               (offset->pointer sym-offset)))))
               (local-set! dst resolved)))))

      (_ *unspecified*))

    ;; Increment IP.
    (set-basm-ip! basm (+ (basm-ip basm) (hashq-ref *vm-op-sizes* (car op))))
    basm)
  (let ((name (or (and (procedure? program-or-addr)
                       (procedure-name program-or-addr))
                  (string->symbol
                   (format #f "anon:~a" program-or-addr))))
        (prim-op? (and (primitive? program-or-addr)
                       program-or-addr))
        (free-vars (or (and (program? program-or-addr)
                            (list->vector
                             (program-free-variables program-or-addr)))
                       (and (closure? program-or-addr)
                            (closure-free-vars program-or-addr))
                       (make-vector 0))))
    ;; (format #t "basm: ~a (~a)~%" name (ensure-program-addr program-or-addr))
    (hashq-set! seen (ensure-program-addr program-or-addr) #t)
    (fold-program-code f
                       (make-basm name args free-vars prim-op?)
                       (ensure-program-addr program-or-addr) #:raw? #t)))
