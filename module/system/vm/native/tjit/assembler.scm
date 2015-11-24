;;;; Assembler for VM tjit engine

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
;;; Primitives for native code used in vm-tjit engine.
;;;
;;; Code:

(define-module (system vm native tjit assembler)
  #:use-module (ice-9 format)
  #:use-module (ice-9 match)
  #:use-module (language cps types)
  #:use-module (language tree-il primitives)
  #:use-module (srfi srfi-9)
  #:use-module (system foreign)
  #:use-module ((system base types) #:select (%word-size))
  #:use-module (system vm native debug)
  #:use-module (system vm native lightning)
  #:use-module (system vm native tjit registers)
  #:use-module (system vm native tjit snapshot)
  #:use-module (system vm native tjit variables)
  #:export (*native-prim-procedures*
            *native-prim-types*
            *scm-false*
            *scm-true*
            *scm-undefined*
            *scm-unspecified*
            *scm-null*
            make-asm
            asm-fp-offset
            asm-out-code
            set-asm-out-code!
            set-asm-exit!
            asm-end-address
            asm-volatiles
            make-negative-pointer
            make-signed-pointer
            spilled-offset
            constant-word
            move
            jump
            jumpi
            sp-ref
            sp-set!
            memory-ref
            memory-set!
            memory-ref/f
            memory-set!/f
            scm-from-double
            scm-frame-dynamic-link
            scm-frame-set-dynamic-link!
            scm-frame-return-address
            scm-frame-set-return-address!
            scm-real-value
            registers-offset
            load-vp
            store-vp
            load-vp->fp
            store-vp->fp
            vm-cache-sp
            vm-sync-ip
            vm-sync-sp
            vm-sync-fp
            vm-handle-interrupts))

(define (make-negative-pointer addr)
  "Make negative pointer with ADDR."
  (when (< 0 addr)
    (error "make-negative-pointer: expecting negative address" addr))
  (make-pointer (+ (expt 2 (* 8 %word-size)) addr)))

(define (make-signed-pointer addr)
  (if (<= 0 addr)
      (make-pointer addr)
      (make-negative-pointer addr)))

(define-syntax-rule (constant-word i)
  (imm (* (ref-value i) %word-size)))

(define %word-size-in-bits
  (inexact->exact (/ (log %word-size) (log 2))))


;;;
;;; Primitives
;;;

;;; Primitives used for vm-tjit engine.  Primitives defined here are used during
;;; compilation of traced data to native code, and possibly useless for ordinal
;;; use as scheme procedure except for managing comment as document.
;;;
;;; Need at least 3 general purpose scratch registers, and 3 floating point
;;; scratch registers. Currently using R0, R1, and R2 for general purpose, F0,
;;; F1, and F2 for floating point.

(define *native-prim-arities* (make-hash-table))
(define *native-prim-procedures* (make-hash-table))
(define *native-prim-types* (make-hash-table))

(define (arity-of-args args)
  (cond
   ((null? args)
    '(0 . 0))
   ((eq? (car args) 'dst)
    `(1 . ,(length (cdr args))))
   (else
    `(0 . ,(length args)))))

(define-syntax-parameter asm
  (lambda (x)
    (syntax-violation 'asm "asm used outside of primitive definition" x)))

(define-syntax define-prim
  (syntax-rules ()
    ((_ (name (ty arg) ...) <body>)
     (begin
       (define (name asm-in-arg arg ...)
         (let ((verbosity (lightning-verbosity)))
           (when (and verbosity (<= 5 verbosity))
             (jit-note (format #f "~a" `(name ,arg ...)) 0))
           (debug 4 ";;; (~12a ~{~a~^ ~})~%" 'name `(,arg ...)))
         (syntax-parameterize ((asm (identifier-syntax asm-in-arg)))
           <body>))
       (hashq-set! *native-prim-procedures* 'name name)
       (hashq-set! *native-prim-arities* 'name (arity-of-args '(arg ...)))
       (hashq-set! *native-prim-types* 'name `(,ty ...))))))


;;;
;;; Scheme constants
;;;

(define *scm-false*
  (scm->pointer #f))

(define *scm-true*
  (scm->pointer #t))

(define *scm-unspecified*
  (scm->pointer *unspecified*))

(define *scm-undefined*
  (make-pointer #x904))

(define *scm-null*
  (scm->pointer '()))


;;;
;;; SCM macros
;;;

(define-syntax scm-cell-object
  (syntax-rules ()
    ((_ dst obj 0)
     (jit-ldr dst obj))
    ((_ dst obj 1)
     (jit-ldxi dst obj (imm %word-size)))
    ((_ dst obj n)
     (jit-ldxi dst obj (imm (* n %word-size))))))

(define-syntax-rule (scm-cell-type dst src)
  (scm-cell-object dst src 0))

(define-syntax-rule (scm-typ16 dst obj)
  (jit-andi dst obj (imm #xffff)))

(define-syntax-rule (scm-real-value dst src)
  (jit-ldxi-d dst src (imm (* 2 %word-size))))

(define %scm-from-double
  (dynamic-pointer "scm_do_inline_from_double" (dynamic-link)))

(define-syntax-rule (scm-from-double dst src)
  (begin
    (jit-prepare)
    (jit-pushargr %thread)
    (jit-pushargr-d src)
    (jit-calli %scm-from-double)
    (jit-retval dst)))

(define %scm-inline-cons
  (dynamic-pointer "scm_do_inline_cons" (dynamic-link)))

(define %scm-async-tick
  (dynamic-pointer "scm_async_tick" (dynamic-link)))

(define-syntax-rule (scm-frame-return-address dst vp->fp)
  (jit-ldr dst vp->fp))

(define-syntax-rule (scm-frame-set-return-address! vp->fp src)
  (jit-str vp->fp src))

(define-syntax-rule (scm-frame-dynamic-link dst vp->fp)
  (jit-ldxi dst vp->fp (imm %word-size)))

(define-syntax-rule (scm-frame-set-dynamic-link! vp->fp src)
  (jit-stxi (imm %word-size) vp->fp src))

(define-syntax-rule (moffs mem)
  (let ((n (+ (ref-value mem) *num-volatiles*)))
    (make-negative-pointer (* (- -2 n) %word-size))))

(define registers-offset
  (make-negative-pointer (* -1 %word-size)))

(define (volatile-offset reg)
  (let ((n (- (ref-value reg) *num-non-volatiles*)))
    (make-negative-pointer (* (- -2 n) %word-size))))

(define (spilled-offset mem)
  (moffs mem))

(define-syntax-rule (load-vp dst)
  (jit-ldr dst %fp))

(define-syntax-rule (store-vp src)
  (jit-str %fp src))

(define-syntax-rule (load-vp->fp dst vp)
  (jit-ldxi dst vp (imm (* 2 %word-size))))

(define-syntax-rule (store-vp->fp vp src)
  (jit-stxi (imm (* 2 %word-size)) vp src))

(define-syntax-rule (vm-cache-sp vp)
  (jit-ldxi %sp vp (make-pointer %word-size)))

(define-syntax-rule (vm-sync-ip src)
  (let ((vp (if (eq? src r0) r1 r0)))
    (load-vp vp)
    (jit-str vp src)))

(define-syntax-rule (vm-sync-sp src)
  (let ((vp (if (eq? src r0) r1 r0)))
    (load-vp vp)
    (jit-stxi (imm %word-size) vp src)))

(define-syntax-rule (vm-sync-fp src)
  (let ((vp (if (eq? src r0) r1 r0)))
    (load-vp vp)
    (store-vp->fp vp src)))

(define-syntax-rule (sp-ref dst n)
  (if (= 0 n)
      (jit-ldr dst %sp)
      (jit-ldxi dst %sp (make-signed-pointer (* n %word-size)))))

(define-syntax-rule (sp-set! n src)
  (if (= 0 n)
      (jit-str %sp src)
      (jit-stxi (make-signed-pointer (* n %word-size)) %sp src)))

(define-syntax-rule (vm-thread-pending-asyncs dst)
  (jit-ldxi dst %thread (imm #x104)))

(define-syntax-rule (vm-handle-interrupts asm-arg)
  (let ((next (jit-forward)))
    (vm-thread-pending-asyncs r0)
    (jump (jit-bmci r0 (imm 1)) next)
    (for-each store-volatile (asm-volatiles asm-arg))
    (jit-prepare)
    (jit-pushargr r0)
    (jit-calli %scm-async-tick)
    (load-vp r0)
    (vm-cache-sp r0)
    (for-each load-volatile (asm-volatiles asm-arg))
    (jit-link next)))

(define (store-volatile src)
  (jit-stxi (volatile-offset src) %fp (gpr src)))

(define (load-volatile dst)
  (jit-ldxi (gpr dst) %fp (volatile-offset dst)))

(define-syntax-rule (push-gpr-or-mem arg overwritten?)
  (cond
   (overwritten?
    (jit-ldxi r0 %fp (volatile-offset arg))
    (jit-pushargr r0))
   ((gpr? arg)
    (jit-pushargr (gpr arg)))
   ((memory? arg)
    (memory-ref r0 arg)
    (jit-pushargr r0))
   (else
    (error "push-gpr-or-mem: unknown arg" arg))))

(define-syntax-rule (retval-to-gpr-or-mem dst)
  (cond
   ((gpr? dst)
    (jit-retval (gpr dst)))
   ((memory? dst)
    (jit-retval r0)
    (memory-set! dst r0))
   (else
    (error "retval-to-gpr-or-mem: unknown dst" dst))))


;;;
;;; Predicates
;;;

(define-syntax-rule (scm-imp obj)
  (jit-bmsi obj (imm 6)))

(define-syntax-rule (scm-inump obj)
  (jit-bmsi obj (imm (@@ (system base types) %tc2-int))))

(define-syntax-rule (scm-not-inump obj)
  (jit-bmci obj (imm (@@ (system base types) %tc2-int))))

(define-syntax-rule (scm-realp tag)
  (jit-beqi tag (imm (@@ (system base types) %tc16-real))))

(define-syntax-rule (scm-not-realp tag)
  (jit-bnei tag (imm (@@ (system base types) %tc16-real))))


;;;
;;; Assembler state
;;;

(define-record-type <asm>
  (%make-asm volatiles exit out-code end-address)
  asm?

  ;; Volatile registers in use.
  (volatiles asm-volatiles)

  ;; Current exit to jump.
  (exit asm-exit set-asm-exit!)

  ;; Pointer of native code for current side exit.
  (out-code asm-out-code set-asm-out-code!)

  ;; Pointer of native code at the end of parent trace.
  (end-address asm-end-address))

(define (make-asm env end-address)
  (define (volatile-regs-in-use env)
    (hash-fold (lambda (_ reg acc)
                 (if (and (gpr? reg)
                          (<= *num-non-volatiles* (ref-value reg)))
                     (cons reg acc)
                     acc))
               '()
               env))
  (let ((volatiles (volatile-regs-in-use env)))
    (debug 1 ";;; make-asm: volatiles=~a~%" volatiles)
    (%make-asm volatiles #f #f end-address)))

(define-syntax jump
  (syntax-rules ()
    ((_ label)
     (jit-patch-at (jit-jmpi) label))
    ((_ condition label)
     (jit-patch-at condition label))))

(define-syntax jumpi
  (syntax-rules ()
    ((_ address)
     (jit-patch-abs (jit-jmpi) address))))

(define-syntax-rule (memory-ref dst src)
  (cond
   ((not (memory? src))
    (error "memory-ref: not a memory" src))
   (else
    (jit-ldxi dst %fp (moffs src)))))

(define-syntax-rule (memory-ref/f dst src)
  (cond
   ((not (memory? src))
    (error "memory-ref/f: not a memory" src))
   (else
    (jit-ldxi-d dst %fp (moffs src)))))

(define-syntax-rule (memory-set! dst src)
  (cond
   ((not (memory? dst))
    (error "memory-set!: not a memory" dst))
   (else
    (jit-stxi (moffs dst) %fp src))))

(define-syntax-rule (memory-set!/f dst src)
  (cond
   ((not (memory? dst))
    (error "memory-set!/f: not a memory" dst))
   (else
    (jit-stxi-d (moffs dst) %fp src))))

(define-syntax-rule (emit-side-exit)
  "Emit native code of side exit.

This macro emits native code which does jumping to current side exit. Assuming
that the `out-code' of ASM contains native code for next side exit.

Side trace reuses native code which does %rsp shifting from parent trace's
epilog part. Native code of side trace does not reset %rsp, since it uses
`jit-tramp'."
  (jumpi (asm-out-code asm)))

(define-syntax-rule (current-exit)
  (asm-exit asm))

(define (move dst src)
  (cond
   ((and (gpr? dst) (constant? src))
    (jit-movi (gpr dst) (constant src)))
   ((and (gpr? dst) (gpr? src))
    (jit-movr (gpr dst) (gpr src)))
   ((and (gpr? dst) (memory? src))
    (memory-ref r0 src)
    (jit-movr (gpr dst) r0))

   ((and (fpr? dst) (constant? src))
    (let ((val (ref-value src)))
      (cond
       ((and (number? val) (flonum? val))
        (jit-movi-d (fpr dst) (constant src)))
       ((and (number? val) (exact? val))
        (jit-movi r0 (constant src))
        (jit-extr-d (fpr dst) r0))
       (else
        (debug 3 "XXX move: ~a ~a~%" dst src)))))
   ((and (fpr? dst) (fpr? src))
    (jit-movr-d (fpr dst) (fpr src)))
   ((and (fpr? dst) (memory? src))
    (memory-ref/f f0 src)
    (jit-movr-d (fpr dst) f0))

   ((and (memory? dst) (constant? src))
    (let ((val (ref-value src)))
      (cond
       ((fixnum? val)
        (jit-movi r0 (constant src))
        (memory-set! dst r0))
       ((flonum? val)
        (jit-movi-d f0 (constant src))
        (memory-set!/f dst f0)))))
   ((and (memory? dst) (gpr? src))
    (memory-set! dst (gpr src)))
   ((and (memory? dst) (fpr? src))
    (memory-set!/f dst (fpr src)))
   ((and (memory? dst) (memory? src))
    (memory-ref r0 src)
    (memory-set! dst r0))

   (else
    (debug 1 "XXX move: ~a ~a~%" dst src))))


;;;
;;; Guards
;;;

(define-syntax define-binary-int-guard
  (lambda (x)
    "Macro for defining guard primitive which takes two int arguments.

`define-binary-int-guard NAME CONST-CONST-OP REG-CONST-OP REG-REG-OP' will
define a primitive named NAME. Uses CONST-CONST-OP when both arguments matched
`constant?' predicate. Uses REG-CONST-OP when the first argument matched `gpr?'
or `memory?' predicate while the second was constant. And, uses REG-REG-OP when
both arguments were register or memory."
    (syntax-case x ()
      ((_ name const-const-op reg-const-op reg-reg-op)
       #`(define-prim (name (int a) (int b))
           (cond
            ((and (constant? a) (constant? b))
             (when (const-const-op (ref-value a) (ref-value b))
               (jump (current-exit))))
            ((and (constant? a) (gpr? b))
             (jit-movi r0 (constant a))
             (jump (reg-reg-op r0 (gpr b)) (current-exit)))
            ((and (constant? a) (memory? b))
             (jit-movi r0 (constant a))
             (memory-ref r1 b)
             (jump (reg-reg-op r0 r1) (current-exit)))

            ((and (gpr? a) (constant? b))
             (jump (reg-const-op (gpr a) (constant b)) (current-exit)))
            ((and (gpr? a) (gpr? b))
             (jump (reg-reg-op (gpr a) (gpr b)) (current-exit)))
            ((and (gpr? a) (memory? b))
             (memory-ref r0 b)
             (jump (reg-reg-op (gpr a) r0) (current-exit)))

            ((and (memory? a) (constant? b))
             (memory-ref r0 a)
             (jump (reg-const-op r0 (constant b))  (current-exit)))
            ((and (memory? a) (gpr? b))
             (memory-ref r0 a)
             (jump (reg-reg-op r0 (gpr b)) (current-exit)))
            ((and (memory? a) (memory? b))
             (memory-ref r0 a)
             (memory-ref r1 b)
             (jump (reg-reg-op r0 r1) (current-exit)))

            (else
             (error #,(symbol->string (syntax->datum #'name)) a b))))))))

;; Auxiliary procedure for %ne.
(define (!= a b) (not (= a b)))

(define-binary-int-guard %eq != jit-bnei jit-bner)
(define-binary-int-guard %ne = jit-beqi jit-beqr)
(define-binary-int-guard %lt >= jit-bgei jit-bger)
(define-binary-int-guard %ge < jit-blti jit-bltr)

(define-prim (%flt (double a) (double b))
  (let ((next (jit-forward)))
    (cond
     ((and (constant? a) (fpr? b))
      (jit-movi-d f0 (constant a))
      (jump (jit-bltr-d f0 (fpr b)) next))

     ((and (fpr? a) (constant? b))
      (jump (jit-blti-d (fpr a) (constant b)) next))
     ((and (fpr? a) (fpr? b))
      (jump (jit-bltr-d (fpr a) (fpr b)) next))

     (else
      (error "%flt" a b)))
    (emit-side-exit)
    (jit-link next)))

(define-prim (%fge (double a) (double b))
  (let ((next (jit-forward)))
    (cond
     ((and (fpr? a) (fpr? b))
      (jump (jit-bger-d (fpr a) (fpr b)) next))
     ((and (fpr? a) (memory? b))
      (memory-ref/f f0 b)
      (jump (jit-bger-d (fpr a) f0) next))

     ((and (memory? a) (memory? b))
      (memory-ref/f f0 a)
      (memory-ref/f f1 b)
      (jump (jit-bger-d f0 f1) next))

     (else
      (error "%fge" a b)))
    (emit-side-exit)
    (jit-link next)))

;;; Scheme procedure call.
(define-prim (%pcall (void proc))
  (let* ((vp r0)
         (vp->fp r1))
    (load-vp vp)
    (load-vp->fp vp->fp vp)
    (jit-subi vp->fp vp->fp (imm (* (ref-value proc) %word-size)))
    (store-vp->fp vp vp->fp)))

;;; Return from procedure call. Shift current FP to the one from dynamic
;;; link. Guard with return address, checks whether it match with the IP used at
;;; the time of compilation.
(define-prim (%return (void ip))
  (let ((vp r0)
        (vp->fp r1)
        (tmp r2))
    (when (not (constant? ip))
      (error "%return: got non-constant ip"))
    (load-vp vp)
    (load-vp->fp vp->fp vp)
    (scm-frame-return-address tmp vp->fp)
    (jump (jit-bnei tmp (constant ip)) (current-exit))

    (scm-frame-dynamic-link tmp vp->fp)
    (jit-lshi tmp tmp (imm %word-size-in-bits))
    (jit-addr vp->fp vp->fp tmp)
    (store-vp->fp vp vp->fp)))


;;;
;;; Exact integer
;;;

;;; XXX: Manage overflow and underflow.
(define-syntax define-binary-int-prim
  (lambda (x)
    (syntax-case x ()
      ((_ name const-const-op reg-const-op reg-reg-op)
       #`(define-prim (name (int dst) (int a) (int b))
           (cond
            ((and (gpr? dst) (constant? a) (constant? b))
             (let ((result (const-const-op (ref-value a) (ref-value b))))
               (jit-movi (gpr dst) (make-signed-pointer result))))
            ((and (gpr? dst) (gpr? a) (constant? b))
             (reg-const-op (gpr dst) (gpr a) (constant b)))
            ((and (gpr? dst) (gpr? a) (gpr? b))
             (reg-reg-op (gpr dst) (gpr a) (gpr b)))
            ((and (gpr? dst) (gpr? a) (memory? b))
             (memory-ref r0 b)
             (reg-reg-op (gpr dst) (gpr a) r0))
            ((and (gpr? dst) (memory? a) (constant? b))
             (memory-ref r0 a)
             (reg-const-op (gpr dst) r0 (constant b)))
            ((and (gpr? dst) (memory? a) (gpr? b))
             (memory-ref r0 a)
             (reg-reg-op (gpr dst) r0 (gpr b)))
            ((and (gpr? dst) (memory? a) (memory? b))
             (memory-ref r0 a)
             (memory-ref r1 b)
             (reg-reg-op (gpr dst) r0 r1))

            ((and (memory? dst) (constant? a) (constant? b))
             (let ((result (const-const-op (ref-value a) (ref-value b))))
               (jit-movi r0 (make-signed-pointer result))
               (memory-set! dst r0)))
            ((and (memory? dst) (constant? a) (gpr? b))
             (jit-movi r0 (constant a))
             (reg-reg-op r0 r0 (gpr b))
             (memory-set! dst r0))
            ((and (memory? dst) (gpr? a) (constant? b))
             (reg-const-op r0 (gpr a) (constant b))
             (memory-set! dst r0))
            ((and (memory? dst) (gpr? a) (gpr? b))
             (reg-reg-op r0 (gpr a) (gpr b))
             (memory-set! dst r0))
            ((and (memory? dst) (gpr? a) (memory? b))
             (memory-ref r1 b)
             (reg-reg-op r0 (gpr a) r1)
             (memory-set! dst r0))
            ((and (memory? dst) (constant? a) (memory? b))
             (jit-movi r0 (constant a))
             (memory-ref r1 b)
             (reg-reg-op r0 r0 r1)
             (memory-set! dst r0))
            ((and (memory? dst) (memory? a) (constant? b))
             (memory-ref r0 a)
             (reg-const-op r0 r0 (constant b))
             (memory-set! dst r0))
            ((and (memory? dst) (memory? a) (gpr? b))
             (memory-ref r0 a)
             (reg-reg-op r0 r0 (gpr b))
             (memory-set! dst r0))
            ((and (memory? dst) (memory? a) (memory? b))
             (memory-ref r0 a)
             (memory-ref r1 b)
             (reg-reg-op r0 r0 r1)
             (memory-set! dst r0))

            (else
             (error #,(symbol->string (syntax->datum #'name)) dst a b))))))))

(define-binary-int-prim %add + jit-addi jit-addr)
(define-binary-int-prim %sub - jit-subi jit-subr)

(define-prim (%rsh (int dst) (int a) (int b))
  (cond
   ((and (gpr? dst) (gpr? a) (gpr? b))
    (jit-rshr (gpr dst) (gpr a) (gpr b)))
   ((and (gpr? dst) (gpr? a) (constant? b))
    (jit-rshi (gpr dst) (gpr a) (constant b)))
   ((and (gpr? dst) (memory? a) (constant? b))
    (memory-ref r0 a)
    (jit-rshi (gpr dst) r0 (constant b)))

   ((and (memory? dst) (gpr? a) (constant? b))
    (jit-rshi r0 (gpr a) (constant b))
    (memory-set! dst r0))
   ((and (memory? dst) (memory? a) (constant? b))
    (memory-ref r0 a)
    (jit-rshi r0 r0 (constant b))
    (memory-set! dst r0))
   (else
    (error "%rsh" dst a b))))

(define-prim (%lsh (int dst) (int a) (int b))
  (cond
   ((and (gpr? dst) (constant? a) (constant? b))
    (jit-movi (gpr dst) (imm (ash (ref-value a) (ref-value b)))))
   ((and (gpr? dst) (gpr? a) (constant? b))
    (jit-lshi (gpr dst) (gpr a) (constant b)))
   ((and (gpr? dst) (gpr? a) (gpr? b))
    (jit-lshr (gpr dst) (gpr a) (gpr b)))
   ((and (gpr? dst) (memory? a) (constant? b))
    (memory-ref r0 a)
    (jit-lshi (gpr dst) r0 (constant b)))

   ((and (memory? dst) (constant? a) (constant? b))
    (jit-movi r0 (imm (ash (ref-value a) (ref-value b))))
    (memory-set! dst r0))
   ((and (memory? dst) (gpr? a) (constant? b))
    (jit-lshi r0 (gpr a) (constant b))
    (memory-set! dst r0))
   ((and (memory? dst) (memory? a) (constant? b))
    (memory-ref r0 a)
    (jit-lshi r0 r0 (constant b))
    (memory-set! dst r0))
   (else
    (error "%lsh" dst a b))))

(define-prim (%mod (int dst) (int a) (int b))
  (cond
   ((and (gpr? dst) (gpr? a) (constant? b))
    (jit-remi (gpr dst) (gpr a) (constant b)))
   ((and (gpr? dst) (gpr? a) (gpr? b))
    (jit-remr (gpr dst) (gpr a) (gpr b)))
   (else
    (error "%mod" dst a b))))


;;;
;;; Floating point
;;;

;;; XXX: Make lower level operation and rewrite.
(define-prim (%from-double (int dst) (double src))
  (cond
   ((and (gpr? dst) (constant? src))
    (jit-movi-d f0 (constant src))
    (scm-from-double (gpr dst) f0))
   ((and (gpr? dst) (fpr? src))
    (scm-from-double (gpr dst) (fpr src)))
   ((and (gpr? dst) (memory? src))
    (memory-ref/f f0 src)
    (scm-from-double (gpr dst) f0))

   ((and (memory? dst) (constant? src))
    (jit-movi-d f0 (constant src))
    (scm-from-double r0 f0)
    (memory-set! dst r0))
   ((and (memory? dst) (fpr? src))
    (scm-from-double r0 (fpr src))
    (memory-set! dst r0))
   ((and (memory? dst) (memory? src))
    (memory-ref/f f0 src)
    (scm-from-double r0 f0)
    (memory-set! dst r0))
   (else
    (error "XXX: %scm-from-double" dst src))))

(define-prim (%fadd (double dst) (double a) (double b))
  (cond
   ((and (fpr? dst) (constant? a) (fpr? b))
    (jit-addi-d (fpr dst) (fpr b) (constant a)))
   ((and (fpr? dst) (fpr? a) (constant? b))
    (%fadd asm dst b a))
   ((and (fpr? dst) (fpr? a) (fpr? b))
    (jit-addr-d (fpr dst) (fpr a) (fpr b)))

   ((and (memory? dst) (fpr? a) (fpr? b))
    (jit-addr-d f0 (fpr a) (fpr b))
    (memory-set!/f dst f0))
   ((and (memory? dst) (memory? a) (constant? b))
    (memory-ref/f f0 a)
    (jit-addi-d f0 f0 (constant b))
    (memory-set!/f dst f0))
   ((and (memory? dst) (memory? a) (fpr? b))
    (memory-ref/f f0 a)
    (jit-addr-d f0 f0 (fpr b))
    (memory-set!/f dst f0))
   (else
    (error "%fadd" dst a b))))

(define-prim (%fsub (double dst) (double a) (double b))
  (cond
   ((and (fpr? dst) (fpr? a) (fpr? b))
    (jit-subr-d (fpr dst) (fpr a) (fpr b)))
   ((and (fpr? dst) (constant? a) (fpr? b))
    (jit-movi-d f0 (constant a))
    (jit-subr-d (fpr dst) f0 (fpr b)))
   ((and (fpr? dst) (fpr? a) (constant? b))
    (jit-subi-d (fpr dst) (fpr a) (constant b)))

   ((and (memory? dst) (fpr? a) (fpr? b))
    (jit-subr-d f0 (fpr a) (fpr b))
    (memory-set!/f dst f0))
   ((and (memory? dst) (memory? a) (memory? b))
    (memory-ref/f f0 a)
    (memory-ref/f f1 b)
    (jit-subr-d f0 f0 f1)
    (memory-set!/f dst f0))
   (else
    (error "%fsub" dst a b))))

(define-prim (%fmul (double dst) (double a) (double b))
  (cond
   ((and (fpr? dst) (constant? a) (fpr? b))
    (jit-muli-d (fpr dst) (fpr b) (constant a)))
   ((and (fpr? dst) (fpr? a) (constant? b))
    (%fmul asm dst b a))
   ((and (fpr? dst) (fpr? a) (fpr? b))
    (jit-mulr-d (fpr dst) (fpr a) (fpr b)))

   ((and (memory? dst) (constant? a) (fpr? b))
    (jit-muli-d f0 (fpr b) (constant a))
    (memory-set!/f dst f0))
   ((and (memory? dst) (memory? a) (fpr? b))
    (memory-ref/f f0 a)
    (jit-mulr-d f0 f0 (fpr b))
    (memory-set!/f dst f0))
   (else
    (error "%fmul" dst a b))))


;;;
;;; Load and store
;;;

;;; XXX: Not sure whether it's better to couple `xxx-ref' and `xxx-set!'
;;; instructions with expected type as done in bytecode, to have vector-ref,
;;; struct-ref, box-ref, string-ref, fluid-ref, bv-u8-ref ... etc or not. When
;;; instructions specify its operand type, size of CPS will be more compact, but
;;; may loose chances to optimize away type checking instructions.

;; Type check local N with TYPE and load to gpr or memory DST.  Won't work when
;; n is negative.
(define-prim (%fref (int dst) (void n) (void type))
  (let-syntax ((load-constant
                (syntax-rules ()
                  ((_ constant)
                   (begin
                     (jump (jit-bnei r0 constant) (current-exit))
                     (cond
                      ((gpr? dst)
                       (jit-movr (gpr dst) r0))
                      ((memory? dst)
                       (memory-set! dst r0))
                      (else
                       (error "%fref" dst n type))))))))
    (when (or (not (constant? n))
              (not (constant? type)))
      (error "%fref" dst n type))

    (sp-ref r0 (ref-value n))

    (let ((type (ref-value type)))
      (cond
       ((eq? type &exact-integer)
        (jump (scm-not-inump r0) (current-exit))
        (cond
         ((gpr? dst)
          (jit-rshi (gpr dst) r0 (imm 2)))
         ((memory? dst)
          (jit-rshi r0 r0 (imm 2))
          (memory-set! dst r0))))
       ((eq? type &false)
        (load-constant *scm-false*))
       ((eq? type &true)
        (load-constant *scm-true*))
       ((eq? type &unspecified)
        (load-constant *scm-unspecified*))
       ((eq? type &undefined)
        (load-constant *scm-undefined*))
       ((eq? type &null)
        (load-constant *scm-null*))
       ((memq type (list &box &procedure &pair))
        ;; XXX: Add guard for each type.
        (cond
         ((gpr? dst)
          (jit-movr (gpr dst) r0))
         ((memory? dst)
          (memory-set! dst r0))))
       (else
        (error "%fref" dst n type))))))

;; Load frame local to fpr or memory, with type check. This primitive
;; is used for loading floating point number to FPR.
(define-prim (%fref/f (double dst) (void n))
  (let ((exit (jit-forward))
        (next (jit-forward)))
    (when (not (constant? n))
      (error "%fref/f" dst n))
    (sp-ref r0 (ref-value n))
    (jump (scm-imp r0) exit)
    (scm-cell-type r1 r0)
    (scm-typ16 r1 r1)
    (jump (scm-not-realp r1) exit)
    (cond
     ((fpr? dst)
      (scm-real-value (fpr dst) r0))
     ((memory? dst)
      (scm-real-value f0 r0)
      (memory-set!/f dst f0))
     (else
      (error "%fref/f" dst n)))
    (jump next)
    (jit-link exit)
    (emit-side-exit)
    (jit-link next)))

(define-prim (%cref (int dst) (int src) (void n))
  (cond
   ((and (gpr? dst) (constant? src) (constant? n))
    (let ((addr (+ (ref-value src) (* (ref-value n) %word-size))))
      (jit-ldi (gpr dst) (imm addr))))
   ((and (gpr? dst) (gpr? src) (constant? n))
    (jit-ldxi (gpr dst) (gpr src) (constant-word n)))
   ((and (gpr? dst) (fpr? src) (constant? n))
    (jit-truncr-d r0 (fpr src))
    (jit-ldxi (gpr dst) r0 (constant-word n)))
   ((and (gpr? dst) (memory? src) (constant? n))
    (memory-ref r0 src)
    (jit-ldxi (gpr dst) r0 (constant-word n)))

   ((and (memory? dst) (constant? src) (constant? n))
    (let ((addr (+ (ref-value src) (* (ref-value n) %word-size))))
      (jit-ldi r0 (imm addr))
      (memory-set! dst r0)))
   ((and (memory? dst) (gpr? src) (constant? n))
    (jit-ldxi r0 (gpr src) (constant-word n))
    (memory-set! dst r0))
   ((and (memory? dst) (memory? src) (constant? n))
    (memory-ref r0 src)
    (jit-ldxi r0 r0 (constant-word n))
    (memory-set! dst r0))
   (else
    (error "%cref" dst src n))))

(define-prim (%cref/f (double dst) (int src) (void n))
  (cond
   ((and (fpr? dst) (gpr? src) (constant? n))
    (jit-ldxi-d (fpr dst) (gpr src) (constant-word n)))
   ((and (fpr? dst) (memory? src) (constant? n))
    (memory-ref r0 src)
    (jit-ldxi-d (fpr dst) r0 (constant-word n)))

   ((and (memory? dst) (gpr? src) (constant? n))
    (jit-ldxi-d f0 (gpr src) (constant-word n))
    (memory-set!/f dst f0))

   ((and (memory? dst) (memory? src) (constant? n))
    (memory-ref r0 src)
    (jit-ldxi-d f0 r0 (constant-word n))
    (memory-set!/f dst f0))

   (else
    (error "%cref/f" dst src n))))

(define-prim (%cset (int cell) (void n) (int src))
  (cond
   ((and (gpr? cell) (constant? n) (gpr? src))
    (jit-stxi (constant-word n) (gpr cell) (gpr src)))
   ((and (gpr? cell) (constant? n) (memory? src))
    (memory-ref r0 src)
    (jit-stxi (constant-word n) (gpr cell) r0))

   ((and (memory? cell) (constant? n) (gpr? src))
    (memory-ref r0 cell)
    (jit-stxi (constant-word n) r0 (gpr src)))
   ((and (memory? cell) (constant? n) (memory? src))
    (memory-ref r0 cell)
    (memory-ref r1 src)
    (jit-stxi (constant-word n) r0 r1))

   (else
    (error "%cset" cell n src))))


;;;
;;; Heap objects
;;;

;; Call C function `scm_do_inline_cons'. Save volatile registers before calling,
;; restore after getting returned value.
(define-prim (%cons (int dst) (int x) (int y))
  (let ((x-overwritten? (equal? x (argr 1)))
        (y-overwritten? (or (equal? y (argr 1))
                            (equal? y (argr 2)))))
    (for-each (lambda (reg)
                (when (or (and x-overwritten? (equal? reg x))
                          (and y-overwritten? (equal? reg y))
                          (not (equal? reg dst)))
                  (store-volatile reg)))
              (asm-volatiles asm))
    (jit-prepare)
    (jit-pushargr %thread)
    (push-gpr-or-mem x x-overwritten?)
    (push-gpr-or-mem y y-overwritten?)
    (jit-calli %scm-inline-cons)
    (retval-to-gpr-or-mem dst)
    (for-each (lambda (reg)
                (when (not (equal? reg dst))
                  (load-volatile reg)))
              (asm-volatiles asm))))

;;;
;;; Move
;;;

(define-prim (%move (int dst) (int src))
  (move dst src))
