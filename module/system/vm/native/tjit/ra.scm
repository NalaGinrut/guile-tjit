;;;; Compile ANF IR to list of primitive operations

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
;;; Assign registers to ANF IR, compile to list of primitive operations.
;;; Applying naive strategy to assign registers to locals, does nothing
;;; sophisticated such as linear-scan, binpacking, or graph coloring.
;;;
;;; Code:

(define-module (system vm native tjit ra)
  #:use-module (ice-9 format)
  #:use-module (ice-9 match)
  #:use-module (language cps types)
  #:use-module (srfi srfi-9)
  #:use-module (srfi srfi-11)
  #:use-module (system foreign)
  #:use-module (system vm native debug)
  #:use-module (system vm native tjit registers)
  #:use-module (system vm native tjit snapshot)
  #:use-module (system vm native tjit variables)
  #:export ($primlist
            primlist?
            primlist-entry
            primlist-loop
            primlist-initial-locals
            anf->primlist))

;;;
;;; Record type
;;;

;; Record type to hold lists of primitives.
(define-record-type $primlist
  (make-primlist entry loop initial-locals)
  primlist?
  ;; List of primitives for entry clause.
  (entry primlist-entry)

  ;; List of primitives for loop body.
  (loop primlist-loop)

  ;; Initial locals, if any. Used in side trace.
  (initial-locals primlist-initial-locals))


;;;
;;; Auxiliary
;;;

(define-syntax-rule (make-initial-free-gprs)
  (make-vector *num-gpr* #t))

(define-syntax-rule (make-initial-free-fprs)
  (make-vector *num-fpr* #t))

(define-syntax define-register-acquire!
  (syntax-rules ()
    ((_ name num constructor)
     (define (name free-regs)
       (let lp ((i 0))
         (cond
          ((= i num)
           #f)
          ((vector-ref free-regs i)
           (let ((ret (constructor i)))
             (vector-set! free-regs i #f)
             ret))
          (else
           (lp (+ i 1)))))))))

(define-register-acquire! acquire-gpr! *num-gpr* make-gpr)
(define-register-acquire! acquire-fpr! *num-fpr* make-fpr)

(define-syntax-parameter mem-idx
  (lambda (x)
    (syntax-violation 'mem-idx "mem-idx undefined" x)))

(define-syntax-parameter free-gprs
  (lambda (x)
    (syntax-violation 'free-gprs "free-gprs undefined" x)))

(define-syntax-parameter free-fprs
  (lambda (x)
    (syntax-violation 'free-fprs "free-fprs undefined" x)))

(define-syntax-parameter env
  (lambda (x)
    (syntax-violation 'env "env undefined" x)))

(define-syntax-rule (gen-mem)
  (let ((ret (make-memory (variable-ref mem-idx))))
    (variable-set! mem-idx (+ 1 (variable-ref mem-idx)))
    ret))

(define-syntax-rule (set-env! gen var)
  (let ((ret gen))
    (hashq-set! env var ret)
    ret))

(define-syntax-rule (get-mem! var)
  (set-env! (gen-mem) var))

(define-syntax-rule (get-gpr! var)
  (set-env! (or (acquire-gpr! free-gprs)
                (gen-mem))
            var))

(define-syntax-rule (get-fpr! var)
  (set-env! (or (acquire-fpr! free-fprs)
                (gen-mem))
            var))

(define (compile-primlist term arg-env arg-free-gprs arg-free-fprs arg-mem-idx
                          snapshot-id)
  "Compile ANF term to list of primitive operations."
  (syntax-parameterize
      ((env (identifier-syntax arg-env))
       (free-gprs (identifier-syntax arg-free-gprs))
       (free-fprs (identifier-syntax arg-free-fprs))
       (mem-idx (identifier-syntax arg-mem-idx)))
    (define (lookup-prim-type op)
      (hashq-ref (@ (system vm native tjit assembler) *native-prim-types*)
                 op))
    (define (get-arg-types! op dst args)
      (let ((types (lookup-prim-type op)))
        (let lp ((types (if dst
                            (cdr types)
                            types))
                 (args args)
                 (acc '()))
          (match (list types args)
            (((type . types) (arg . args))
             (cond
              ((constant? arg)
               (debug 1 ";;; get-arg-types!: got constant ~a~%" arg)
               (lp types args (cons (make-constant arg) acc)))
              ((symbol? arg)
               (cond
                ((hashq-ref env arg)
                 => (lambda (reg)
                      (debug 1 ";;; get-arg-types!: found ~a as ~a~%"
                             arg reg)
                      (lp types args (cons reg acc))))
                ((= type int)
                 (let ((reg (get-gpr! arg)))
                   (debug 1 ";;; get-arg-types!: ~a to ~a (int)~%" arg reg)
                   (lp types args (cons reg acc))))
                ((= type double)
                 (let ((reg (get-fpr! arg)))
                   (debug 1 ";;; get-arg-types!: ~a to ~a (double)~%" arg reg)
                   (lp types args (cons reg acc))))
                (else
                 (debug 1 ";;; get-arg-types!: unknown type ~a~%" type)
                 (lp types args acc))))
              (else
               (error "get-arg-types!: unknown arg with type" arg type))))
            (_
             (reverse! acc))))))
    (define (get-dst-type! op dst)
      ;; Assign new register. Overwrite register used for dst if type
      ;; differs from already assigned register.
      (let ((type (car (lookup-prim-type op)))
            (assigned (hashq-ref env dst)))
        (cond
         ((and assigned
               (or (and (= type int)
                        (not (fpr? assigned)))
                   (and (= type double)
                        (not (gpr? assigned)))))
          (debug 1 ";;; get-dst-type!: same type assigned to dst~%")
          assigned)
         ((= type int)
          (get-gpr! dst))
         ((= type double)
          (get-fpr! dst))
         (else
          (error "get-dst-types!: unknown type~%" dst type)))))
    (define (ref k)
      (cond
       ((constant? k) (make-constant k))
       ((symbol? k) (hashq-ref env k))
       (else
        (error "compile-primlist: ref not found" k))))
    (define (constant? x)
      (cond
       ((boolean? x) #t)
       ((char? x) #t)
       ((number? x) #t)
       (else #f)))
    (define (compile-term term acc)
      (match term
        (('let (('_ ('%snap id . args))) term1)
         (let ((prim `(%snap ,id ,@(map ref args))))
           (set! snapshot-id id)
           (compile-term term1 (cons prim acc))))
        (('let (('_ (op . args))) term1)
         (let ((prim `(,op ,@(get-arg-types! op #f args))))
           (compile-term term1 (cons prim acc))))
        (('let ((dst (? constant? val))) term1)
         (let* ((reg (cond
                      ((ref dst) => identity)
                      ((flonum? val) (get-fpr! dst))
                      (else (get-gpr! dst))))
                (prim `(%move ,reg ,(make-constant val))))
           (compile-term term1 (cons prim acc))))
        (('let ((dst (? symbol? src))) term1)
         (let* ((src-reg (ref src))
                (dst-reg (cond
                          ((ref dst) => identity)
                          ((gpr? src-reg) (get-gpr! dst))
                          ((fpr? src-reg) (get-fpr! dst))
                          ((memory? src-reg) (get-mem! dst))))
                (prim `(%move ,dst-reg ,src-reg)))
           (compile-term term1 (cons prim acc))))
        (('let ((dst (op . args))) term1)
         ;; Set and get argument types before destination type.
         (let* ((arg-regs (get-arg-types! op dst args))
                (prim `(,op ,(get-dst-type! op dst) ,@arg-regs)))
           (compile-term term1 (cons prim acc))))
        (('loop . _)
         acc)
        ('_
         acc)
        (()
         acc)))

    (let ((plist (reverse! (compile-term term '()))))
      (values plist snapshot-id))))


;;;
;;; ANF to Primitive List
;;;

(define (anf->primlist parent-snapshot initial-snapshot vars term)
  (let ((initial-free-gprs (make-initial-free-gprs))
        (initial-free-fprs (make-initial-free-fprs))
        (initial-mem-idx (make-variable 0))
        (initial-env (make-hash-table))
        (initial-local-x-types (snapshot-locals initial-snapshot)))
    (syntax-parameterize
        ((free-gprs (identifier-syntax initial-free-gprs))
         (free-fprs (identifier-syntax initial-free-fprs))
         (mem-idx (identifier-syntax initial-mem-idx))
         (env (identifier-syntax initial-env)))
      (define-syntax-rule (set-initial-args! initial-args initial-locals)
        (let lp ((args initial-args)
                 (local-x-types initial-locals)
                 (acc '()))
          (match (list args local-x-types)
            (((arg . args) ((local . type) . local-x-types))
             (cond
              ((hashq-ref env arg)
               => (lambda (reg)
                    (lp args local-x-types (cons reg acc))))
              (else
               (let ((reg (if (eq? type &flonum)
                              (get-fpr! arg)
                              (get-gpr! arg))))
                 (lp args local-x-types (cons reg acc))))))
            (_
             (reverse! acc)))))
      (define-syntax-rule (make-var n)
        (string->symbol (string-append "v" (number->string n))))

      (match term
        ;; ANF with entry clause and loop body.
        (`(letrec ((entry (lambda ,entry-args
                            ,entry-body))
                   (loop (lambda ,loop-args
                           ,loop-body)))
            entry)
         (let*-values (((_)
                        (set-initial-args! entry-args initial-local-x-types))
                       ((entry-ops snapshot-idx)
                        (compile-primlist entry-body
                                          env free-gprs free-fprs mem-idx
                                          0))
                       ((loop-ops snapshot-idx)
                        (compile-primlist loop-body
                                          env free-gprs free-fprs mem-idx
                                          snapshot-idx)))
           (make-primlist entry-ops loop-ops '())))

        ;; ANF without loop.
        (`(letrec ((patch (lambda ,patch-args
                            ,patch-body)))
            patch)

         ;; Refill variables. Using the locals assigned to snapshot, which are
         ;; determined at the time of exit from parent trace.
         (match parent-snapshot
           (($ $snapshot id offset nlocals locals variables code ip)
            (when (= (length locals)
                     (length variables))
              (let lp ((variables variables)
                       (locals locals))
                (match (list variables locals)
                  (((var . vars) ((local . type) . locals))
                   (hashq-set! env (make-var local) var)
                   (match var
                     (('gpr . n)
                      (vector-set! free-gprs n #f))
                     (('fpr . n)
                      (vector-set! free-fprs n #f))
                     (('mem . n)
                      (when (<= (variable-ref mem-idx) n)
                        (variable-set! mem-idx (+ n 1)))))
                   (lp vars locals))
                  (_
                   (values))))))
           (_
            (debug 2 ";;; anf->primlist: perhaps loop-less root trace~%")))
         (let*-values (((arg-vars)
                        (set-initial-args! patch-args initial-local-x-types))
                       ((patch-ops snapshot-idx)
                        (compile-primlist patch-body
                                          env free-gprs free-fprs mem-idx
                                          0)))
           (make-primlist patch-ops '() arg-vars)))
        (_
         (error "anf->primlist: malformed term" term))))))
