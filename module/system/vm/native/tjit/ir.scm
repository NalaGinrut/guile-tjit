;;;; Bytecode to CPS IR compiler

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
;;; Compile list of bytecode operations to CPS intermediate representation via
;;; Scheme in (almost) ANF.
;;;
;;; One of the main reasons to convert bytecode to CPS is to do floating point
;;; arithmetic efficiently. VM bytecodes uses integer index to refer locals.
;;; Those locals does not distinguish floating point values from other. In CPS
;;; format, since every variables are named uniquely, it is possible to perform
;;; floating point arithmetic directly with unboxed value in floating point
;;; register inside loop.
;;;
;;; Traced bytecode operations are compiled to CPS IR via Scheme IR. Use of
;;; Scheme as another intermediate representation is because once compiled to
;;; Scheme, compiling to CPS could be done with `(@@ (system base compile)
;;; compile)' procedure.
;;;
;;; Code:

(define-module (system vm native tjit ir)
  #:use-module (ice-9 control)
  #:use-module (ice-9 format)
  #:use-module (ice-9 match)
  #:use-module (language cps)
  #:use-module (language cps intmap)
  #:use-module (language cps intset)
  #:use-module (language cps closure-conversion)
  #:use-module (language cps optimize)
  #:use-module (language cps renumber)
  #:use-module (language cps types)
  #:use-module (language scheme spec)
  #:use-module (rnrs bytevectors)
  #:use-module (srfi srfi-11)
  #:use-module (system base compile)
  #:use-module (system foreign)
  #:use-module (system vm native debug)
  #:use-module (system vm native tjit ra)
  #:use-module (system vm native tjit fragment)
  #:use-module (system vm native tjit parameters)
  #:use-module (system vm native tjit snapshot)
  #:export (trace->primlist
            trace->scm))


;;;
;;; Auxiliary procedures
;;;

(define (to-fixnum scm)
  `(%rsh ,scm 2))

(define (to-double scm)
  `(%cref/f ,scm 2))

(define (make-var index)
  (string->symbol (string-append "v" (number->string index))))

(define (make-vars locals)
  ;; Might better to use other data structure than alist for variables.
  ;; Number of variables won't change after getting the number of locals from
  ;; `accumulate-locals'.
  (map (lambda (n)
         (cons n (make-var n)))
       locals))

(define-syntax-rule (with-frame-ref proc args var type idx)
  (cond
   ((not type)
    `(let ((,var #f))
       ,(proc args)))
   ((= type &flonum)
    `(let ((,var (%fref/f ,idx)))
       ,(proc args)))
   (else
    `(let ((,var (%fref ,idx ,type)))
       ,(proc args)))))

(define (get-initial-offset parent-snapshot)
  ;; Initial offset of root trace is constantly 0. Initial offset of side
  ;; trace is where parent trace left, using offset value from SNAPSHOT.
  (match parent-snapshot
    (($ $snapshot _ offset) offset)
    (_ 0)))

(define (take-snapshot ip dst-offset locals vars snapshot-id
                       local-offset lowest-offset parent-snapshot past-frame)
  (let* ((nlocals (vector-length locals))
         (dst-ip (+ ip (* dst-offset 4)))
         (args-and-indices
          (let lp ((vars vars) (args '()) (indices '()))
            (match vars
              (((n . var) . vars)
               (if (<= lowest-offset n (+ local-offset nlocals))
                   (lp vars (cons var args) (cons n indices))
                   (lp vars args indices)))
              (()
               (cons args indices)))))
         (args (car args-and-indices))
         (indices (cdr args-and-indices))
         (snapshot (make-snapshot snapshot-id
                                  local-offset
                                  lowest-offset
                                  nlocals
                                  locals
                                  parent-snapshot
                                  indices
                                  past-frame
                                  dst-ip)))
    (values `(%snap ,snapshot-id ,@args) snapshot)))

(define (compile-ir trace escape loop? snapshot-id snapshots
                    parent-snapshot past-frame vars)
  (let* ((initial-offset (get-initial-offset parent-snapshot))
         (local-offset initial-offset)
         (lowest-offset (min local-offset 0)))

    (define (take-snapshot-with-locals! ip dst-offset locals)
      (let-values (((ret snapshot)
                    (take-snapshot ip
                                   dst-offset
                                   locals vars
                                   snapshot-id
                                   local-offset
                                   lowest-offset
                                   parent-snapshot
                                   past-frame)))
        (hashq-set! snapshots snapshot-id snapshot)
        (set! snapshot-id (+ snapshot-id 1))
        ret))

    (define (convert-one escape op ip fp ra locals rest)
      (define-syntax br-op-size
        (identifier-syntax 2))
      (define-syntax-rule (local-ref i)
        (vector-ref locals i))
      (define-syntax-rule (var-ref i)
        (assq-ref vars (+ i local-offset)))
      (define-syntax-rule (push-offset! n)
        (set! local-offset (+ local-offset n)))
      (define-syntax-rule (pop-offset! n)
        (begin
          (set! local-offset (- local-offset n))
          (when (< local-offset lowest-offset)
            (set! lowest-offset local-offset))))
      (define (dereference-scm addr)
        (pointer->scm (dereference-pointer (make-pointer addr))))
      (define (take-snapshot! ip dst-offset)
        (take-snapshot-with-locals! ip dst-offset locals))

      (match op
        ;; *** Call and return

        ;; XXX: halt

        (('call proc nlocals)
         ;; When procedure get inlined, taking snapshot of previous frame.
         ;; Contents of previous frame could change in native code. Note that
         ;; frame return address will get checked at the time of `%return'.
         (let* ((dl (cons (- (+ proc local-offset) 2)
                          (make-dynamic-link local-offset)))
                (ra (cons (- (+ proc local-offset) 1)
                          (make-return-address (make-pointer (+ ip (* 2 4))))))
                (vdl (var-ref (- proc 2)))
                (vra (var-ref (- proc 1)))
                (vproc (var-ref proc))
                (rproc (local-ref proc))
                (rproc-addr (pointer-address (scm->pointer rproc)))
                (snapshot (take-snapshot! ip 0)))
           (push-past-frame! past-frame dl ra local-offset locals)
           (push-offset! proc)

           ;; Refilling dynamic link and return address for CPS compilation
           ;; only. These two locals would be restored with values in snapshot
           ;; when taiking side exit.
           `(let ((,vdl #f))
              (let ((,vra ,(+ ip (* 2 4))))
                (let ((_ ,snapshot))
                  ;; Adding `%eq' guard to test the procedure value, to bailout when
                  ;; procedure has been redefined.
                  (let ((_ (%eq ,vproc ,rproc-addr)))
                    ,(convert escape rest)))))))

        (('call-label proc nlocals label)
         (push-offset! proc)
         (convert escape rest))

        ;; XXX: tail-call
        (('tail-call nlocals)
         (convert escape rest))

        ;; XXX: tail-call-label
        ;; XXX: tail-call/shuffle

        (('receive dst proc nlocals)
         (pop-offset! proc)
         (debug 3 ";;; ir.scm:receive~%")
         (debug 3 ";;;   dst=~a proc=~a nlocals=~a~%" dst proc nlocals)
         (debug 3 ";;;   local-offset=~a~%" local-offset)

         ;; `local-offset' could be modified during `convert' with
         ;; `push-offset!' and `pop-offset!'. Wrapping next expression as
         ;; anonymous procedure to prevent overriding variables at this point.
         (let* ((vdst (var-ref dst))
                (vdl (var-ref (- proc 2)))
                (vra (var-ref (- proc 1)))
                (vret (var-ref (+ proc 1)))
                (do-next-convert
                 (lambda ()
                   ;; Two locals below callee procedure in VM frame contain
                   ;; dynamic link and return address. VM interpreter refills
                   ;; these two with #f, doing the same thing.
                   `(let ((,vdl #f))
                      (let ((,vra #f))
                        (let ((,vdst ,vret))
                          ,(convert escape rest))))))
                (proc-offset (+ proc local-offset)))
           (if (<= 0 local-offset)
               (do-next-convert)
               (begin
                 `(let ((_ ,(take-snapshot! ip 0)))
                    ,(let lp ((vars (reverse vars)))
                       (match vars
                         (((n . var) . vars)
                          (cond
                           ((<= local-offset n (+ proc-offset -3))
                            ;; Loading local from lower frame.
                            (let* ((i (- n local-offset))
                                   (val (if (< -1 i (vector-length locals))
                                            (vector-ref locals i)
                                            #f))
                                   (type (type-of val)))
                              (let ((idx (- n local-offset)))
                                (with-frame-ref lp vars var type idx))))
                           (else
                            (lp vars))))
                         (()
                          (do-next-convert)))))))))

        (('receive-values proc allow-extra? nvalues)
         (pop-offset! proc)
         (escape #f))

        (('return src)
         (let* ((vsrc (var-ref src))
                (vdst (var-ref 1))
                (assign (if (eq? vdst vsrc)
                            '()
                            `((,vdst ,vsrc))))
                (snapshot (take-snapshot! ip 0))
                (_ (pop-past-frame! past-frame))
                (body `(let ((_ ,snapshot))
                         ,(if (< 0 local-offset)
                              (convert escape rest)
                              `(let ((_ (%return ,ra)))
                                 ,(convert escape rest))))))
           (if (eq? vdst vsrc)
               body
               `(let ((,vdst ,vsrc))
                  ,body))))

        ;; XXX: return-values

        ;; *** Specialized call stubs

        ;; XXX: subr-call
        ;; XXX: foreign-call
        ;; XXX: continuation-call
        ;; XXX: compose-continuation
        ;; XXX: tail-apply
        ;; XXX: call/cc
        ;; XXX: abort
        ;; XXX: builtin-ref

        ;; *** Function prologues

        ;; XXX: br-if-nargs-ne
        ;; XXX: br-if-nargs-lt
        ;; XXX; br-if-nargs-gt
        ;; XXX: assert-nargs-ee
        ;; XXX: assert-nargs-ge
        ;; XXX: assert-nargs-le
        ;; XXX: alloc-frame
        ;; XXX: reset-frame

        (('assert-nargs-ee/locals expected nlocals)
         (convert escape rest))

        ;; XXX: br-if-npos-gt
        ;; XXX: bind-kw-args
        ;; XXX: bind-rest

        ;; *** Branching instructions

        (('br offset)
         (convert escape rest))

        ;; XXX: br-if-true
        ;; XXX: br-if-null
        ;; XXX: br-if-nil
        ;; XXX: br-if-pair
        ;; XXX: br-if-struct
        ;; XXX: br-if-char
        ;; XXX: br-if-tc7
        ;; XXX: br-if-eq
        ;; XXX: br-if-eqv
        ;; XXX: br-if-equal

        (('br-if-= a b invert? offset)
         (let ((ra (local-ref a))
               (rb (local-ref b))
               (va (var-ref a))
               (vb (var-ref b)))
           (let ((dest (if (= ra rb)
                           (if invert? offset br-op-size)
                           (if invert? br-op-size offset))))
             (cond
              ((and (fixnum? ra) (fixnum? rb))
               `(let ((_ ,(take-snapshot! ip dest)))
                  (let ((_ ,(if (= ra rb) `(%eq ,va ,vb) `(%ne ,va ,vb))))
                    ,(convert escape rest))))
              (else
               (debug 3 "*** ir:convert = ~a ~a~%" ra rb)
               (escape #f))))))

        (('br-if-< a b invert? offset)
         (let ((ra (local-ref a))
               (rb (local-ref b))
               (va (var-ref a))
               (vb (var-ref b)))
           (let ((dest (if (< ra rb)
                           (if invert? offset br-op-size)
                           (if invert? br-op-size offset))))
             (cond
              ((and (fixnum? ra) (fixnum? rb))
               (let ((op (if (< ra rb)
                             `(%lt ,va ,vb)
                             `(%ge ,va ,vb))))
                 `(let ((_ ,(take-snapshot! ip dest)))
                    (let ((_ ,(if (< ra rb) `(%lt ,va ,vb) `(%ge ,va ,vb))))
                      ,(convert escape rest)))))

              ((and (flonum? ra) (flonum? rb))
               `(let ((_ ,(take-snapshot! ip dest)))
                  (let ((_ ,(if (< ra rb) `(%flt ,va ,vb) `(%fge ,va ,vb))))
                    ,(convert escape rest))))
              (else
               (debug 3 "ir:convert < ~a ~a~%" ra rb)
               (escape #f))))))

        ;; XXX: br-if-<=

        ;; *** Lexical binding instructions

        (('mov dst src)
         (let ((vdst (var-ref dst))
               (vsrc (var-ref src)))
           `(let ((,vdst ,vsrc))
              ,(convert escape rest))))

        ;; XXX: long-mov
        ;; XXX: box

        ;; XXX: Reconsider how to manage `box', `box-ref', and `box-set!'.
        ;; Boxing back tagged value every time will make the loop slow, need
        ;; more analysis when the storing could be removed from native code loop
        ;; and delayed to side exit code.
        ;;
        ;; XXX: Add test for nested boxes.

        (('box-ref dst src)
         ;; XXX: Add guard to check type of box contents.
         (let ((vdst (var-ref dst))
               (vsrc (var-ref src))
               (rsrc (and (< src (vector-length locals))
                          (variable-ref (vector-ref locals src)))))
           `(let ((,vdst (%cref ,vsrc 1)))
              ,(cond
                ((flonum? rsrc)
                 `(let ((,vdst ,(to-double vdst)))
                    ,(convert escape rest)))
                ((fixnum? rsrc)
                 `(let ((,vdst ,(to-fixnum vdst)))
                    ,(convert escape rest)))
                (else
                 (convert escape rest))))))

        (('box-set! dst src)
         (let ((vdst (var-ref dst))
               (vsrc (var-ref src))
               (rdst (and (< dst (vector-length locals))
                          (variable-ref (vector-ref locals dst)))))
           (cond
            ((flonum? rdst)
             `(let ((,vsrc (%from-double ,vsrc)))
                (let ((_ (%cset ,vdst 1 ,vsrc)))
                  ,(convert escape rest))))
            ((fixnum? rdst)
             `(let ((,vsrc (%lsh ,vsrc 2)))
                (let ((,vsrc (%add ,vsrc 2)))
                  (let ((_ (%cset ,vdst 1 ,vsrc)))
                    ,(convert escape rest)))))
            (else
             `(let ((_ (%cset ,vdst 1 ,vsrc)))
                ,(convert escape rest))))))

        ;; XXX: make-closure
        ;; XXX: free-ref
        ;; XXX: free-set!

        ;; *** Immediates and statically allocated non-immediates

        (('make-short-immediate dst low-bits)
         ;; XXX: `make-short-immediate' could be used for other value than small
         ;; integer, e.g: '(). Check type from value of `low-bits' and choose
         ;; the type appropriately.
         `(let ((,(var-ref dst) ,(ash low-bits -2)))
            ,(convert escape rest)))

        (('make-long-immediate dst low-bits)
         `(let ((,(var-ref dst) ,(ash low-bits -2)))
            ,(convert escape rest)))

        (('make-long-long-immediate dst high-bits low-bits)
         `(let ((,(var-ref dst)
                 ,(ash (logior (ash high-bits 32) low-bits) -2)))
            ,(convert escape rest)))

        ;; XXX: make-non-immediate

        (('static-ref dst offset)
         `(let ((,(var-ref dst) ,(dereference-scm (+ ip (* 4 offset)))))
            ,(convert escape rest)))

        ;; XXX: static-set!
        ;; XXX: static-patch!

        ;; *** Mutable top-level bindings

        ;; XXX: current-module
        ;; XXX: resolve
        ;; XXX: define!

        (('toplevel-box dst var-offset mod-offset sym-offset bound?)
         (let ((vdst (var-ref dst))
               (src (pointer-address
                     (scm->pointer
                      (dereference-scm (+ ip (* var-offset 4)))))))
           `(let ((,vdst ,src))
              ,(convert escape rest))))

        ;; XXX: module-box

        ;; *** The dynamic environment

        ;; XXX: prompt
        ;; XXX: wind
        ;; XXX: unwind
        ;; XXX: push-fluid
        ;; XXX: pop-fluid
        ;; XXX: fluid-ref
        ;; XXX: fluid-set

        ;; *** Strings, symbols, and keywords

        ;; XXX: string-length
        ;; XXX: string-ref
        ;; XXX: string->number
        ;; XXX: string->symbol
        ;; XXX: symbol->keyword

        ;; *** Pairs

        ;; XXX: cons
        ;; XXX: car
        ;; XXX: cdr
        ;; XXX: set-car!
        ;; XXX: set-cdr!

        ;; *** Numeric operations

        (('add dst a b)
         (let ((rdst (local-ref dst))
               (ra (local-ref a))
               (rb (local-ref b))
               (vdst (var-ref dst))
               (va (var-ref a))
               (vb (var-ref b)))
           (cond
            ((and (fixnum? ra) (fixnum? rb))
             `(let ((,vdst (%add ,va ,vb)))
                ,(convert escape rest)))
            ((and (flonum? ra) (flonum? rb))
             `(let ((,vdst (%fadd ,va ,vb)))
                ,(convert escape rest)))
            (else
             (debug 3 "ir:convert add ~a ~a ~a~%" rdst ra rb)
             (escape #f)))))

        (('add1 dst src)
         (let ((rdst (local-ref dst))
               (rsrc (local-ref src))
               (vdst (var-ref dst))
               (vsrc (var-ref src)))
           (cond
            ((fixnum? rsrc)
             `(let ((,vdst (%add ,vsrc 1)))
                ,(convert escape rest)))
            (else
             (debug 3 "ir:convert add1 ~a ~a" rdst rsrc)
             (escape #f)))))

        (('sub dst a b)
         (let ((rdst (local-ref dst))
               (ra (local-ref a))
               (rb (local-ref b))
               (vdst (var-ref dst))
               (va (var-ref a))
               (vb (var-ref b)))
           (cond
            ((and (fixnum? ra) (fixnum? rb))
             `(let ((,vdst (%sub ,va ,vb)))
                ,(convert escape rest)))
            ((and (flonum? ra) (flonum? rb))
             `(let ((,vdst (%fsub ,va ,vb)))
                ,(convert escape rest)))
            (else
             (debug 3 "ir:convert sub ~a ~a ~a~%" rdst ra rb)
             (escape #f)))))

        (('sub1 dst src)
         (let ((rdst (local-ref dst))
               (rsrc (local-ref src))
               (vdst (var-ref dst))
               (vsrc (var-ref src)))
           (cond
            ((fixnum? rsrc)
             `(let ((,vdst (%sub ,vsrc 1)))
                ,(convert escape rest)))
            (else
             (debug 3 "ir:convert sub1 ~a ~a~%" rdst rsrc)
             (escape #f)))))

        (('mul dst a b)
         (let ((rdst (local-ref dst))
               (ra (local-ref a))
               (rb (local-ref b))
               (vdst (var-ref dst))
               (va (var-ref a))
               (vb (var-ref b)))
           (cond
            ((and (flonum? ra) (flonum? rb))
             `(let ((,vdst (%fmul ,va ,vb)))
                ,(convert escape rest)))
            (else
             (debug 3 "*** ir:convert: NYI mul ~a ~a ~a~%" rdst ra rb)
             (escape #f)))))

        ;; XXX: div
        ;; XXX: quo
        ;; XXX: rem

        (('mod dst a b)
         (let ((rdst (local-ref dst))
               (ra (local-ref a))
               (rb (local-ref b))
               (vdst (var-ref dst))
               (va (var-ref a))
               (vb (var-ref b)))
           (cond
            ((and (fixnum? ra) (fixnum? rb))
             `(let ((,vdst (%mod ,va ,vb)))
                ,(convert escape rest)))
            (else
             (debug 3 "*** ir:convert: NYI mod ~a ~a ~a~%" rdst ra rb)
             (escape #f)))))

        ;; XXX: ash
        ;; XXX: logand
        ;; XXX: logior
        ;; XXX: logxor
        ;; XXX: make-vector
        ;; XXX: make-vector/immediate
        ;; XXX: vector-length
        ;; XXX: vector-ref
        ;; XXX: vector-ref/immediate

        ;; XXX: vector-set!
        (('vector-set! dst idx src)
         (let ((rdst (local-ref dst))
               (rsrc (local-ref src))
               (ridx (local-ref idx))
               (vdst (var-ref dst))
               (vsrc (var-ref src))
               (vidx (var-ref idx)))
           (cond
            ((and (vector? rsrc) (fixnum? ridx))
             `(let ((_ (%vector-set! ,vdst ,vsrc ,vidx)))
                ,(convert escape rest)))
            (else
             (debug 3 "*** ir.scm:convert: NYI vector-set! ~a ~a ~a~%"
                    rdst rsrc ridx)
             (escape #f)))))

        ;; XXX: vector-set!/immediate

        ;; *** Structs and GOOPS

        ;; XXX: struct-vtable
        ;; XXX: allocate-struct/immediate
        ;; XXX: struct-ref/immediate
        ;; XXX: struct-set!/immediate
        ;; XXX: class-of

        ;; *** Arrays, packed uniform arrays, and bytevectors

        ;; XXX: load-typed-array
        ;; XXX: make-array
        ;; XXX: bv-u8-ref
        ;; XXX: bv-s8-ref
        ;; XXX: bv-u16-ref
        ;; XXX: bv-s16-ref
        ;; XXX: bv-u32-ref
        ;; XXX: bv-s32-ref
        ;; XXX: bv-u64-ref
        ;; XXX: bv-s64-ref
        ;; XXX: bv-f32-ref
        ;; XXX: bv-f64-ref
        ;; XXX: bv-u8-set!
        ;; XXX: bv-s8-set!
        ;; XXX: bv-u16-set!
        ;; XXX: bv-s16-set!
        ;; XXX: bv-u32-set!
        ;; XXX: bv-s32-set!
        ;; XXX: bv-u64-set!
        ;; XXX: bv-s64-set!
        ;; XXX: bv-f32-set!
        ;; XXX: bv-f64-set!

        ;; *** Move above

        ;; XXX: br-if-logtest
        ;; XXX: allocate-struct
        ;; XXX: struct-ref
        ;; XXX: struct-set!

        (op
         (debug 3 "*** ir:convert: NYI ~a~%" (car op))
         (escape #f))))

    (define (convert escape trace)
      (match trace
        (((op ip fp ra locals) . ())
         ;; Last operation is wrapped in a thunk, to assign snapshot ID
         ;; in last expression after taking snapshots from guards in
         ;; traced operations.
         ;;
         ;; Trace with loop will emit `loop', which is the name of
         ;; procedure for looping the body of Scheme IR emitted in
         ;; `make-scm'.
         ;;
         ;; Side trace or loop-less root trace are apturing CPS variables
         ;; with `take-snapshot!' at the end, so that the native code can
         ;; pass the register information to linked code.
         ;;
         (let ((last-op
                (if loop?
                    (lambda ()
                      `(loop ,@(reverse (map cdr vars))))
                    (lambda ()
                      `(let ((_ ,(take-snapshot-with-locals!
                                  *ip-key-jump-to-linked-code*
                                  0
                                  locals)))
                         _)))))
           (convert-one escape op ip fp ra locals last-op)))
        (((op ip fp ra locals) . rest)
         (convert-one escape op ip fp ra locals rest))
        (last-op
         (or (and (procedure? last-op)
                  (last-op))
             (error "ir.scm: last arg was not a procedure" last-op)))))

    (convert escape trace)))

;;;
;;; Scheme ANF compiler
;;;

(define (trace->scm fragment exit-id loop? trace)
  (define-syntax root-trace?
    (identifier-syntax (not fragment)))

  (define (get-initial-snapshot-id)
    ;; For root trace, initial snapshot already added in `make-scm'.
    (if root-trace? 1 0))

  (let* ((parent-snapshot
          (and fragment
               (hashq-ref (fragment-snapshots fragment) exit-id)))
         (initial-offset (get-initial-offset parent-snapshot))
         (local-offset initial-offset)
         (past-frame (accumulate-locals local-offset trace))
         (local-indices (past-frame-local-indices past-frame))
         (vars (make-vars local-indices))
         (lowest-offset (min local-offset 0))
         (snapshots (make-hash-table))
         (snapshot-id (get-initial-snapshot-id)))

    (define (take-snapshot! ip dst-offset locals vars)
      (let-values (((ret snapshot)
                    (take-snapshot ip
                                   dst-offset
                                   locals vars
                                   snapshot-id
                                   local-offset
                                   lowest-offset
                                   parent-snapshot
                                   past-frame)))
        (hashq-set! snapshots snapshot-id snapshot)
        (set! snapshot-id (+ snapshot-id 1))
        ret))

    (define (make-vars-from-parent vars
                                   locals-from-parent
                                   offset-from-parent)
      (let lp ((vars vars) (acc '()))
        (match vars
          (((n . var) . vars)
           ;; When parent-snapshot-offset is negative, side trace entered from a
           ;; side exit which is somewhere in the middle of bytecode of lower
           ;; frame than the beginning of the parent trace.
           (let ((m (if (< offset-from-parent 0)
                        (- n offset-from-parent)
                        n)))
             (if (assq-ref locals-from-parent m)
                 (lp vars (cons (cons n var) acc))
                 (lp vars acc))))
          (()
           (reverse! acc)))))

    (let* ((args (map make-var (reverse local-indices)))
           (initial-ip (cadr (car trace)))
           (initial-locals (list-ref (car trace) 4))
           (initial-nlocals (vector-length initial-locals))
           (parent-snapshot-locals (match parent-snapshot
                                     (($ $snapshot _ _ _ locals) locals)
                                     (_ #f)))
           (vars-from-parent (make-vars-from-parent vars
                                                    parent-snapshot-locals
                                                    initial-offset))
           (args-from-parent (reverse (map cdr vars-from-parent)))
           (local-indices-from-parent (map car vars-from-parent)))

      (define (add-initial-loads exp-body)
        (debug 3 ";;; add-initial-loads:~%")
        (debug 3 ";;;   initial-locals=~a~%" initial-locals)
        (let ((snapshot0 (hashq-ref snapshots 0)))
          (define (type-from-snapshot n)
            (let ((i (- n (snapshot-offset snapshot0))))
              (and (< -1 i)
                   (< i (vector-length initial-locals))
                   (type-of (vector-ref initial-locals i)))))
          (define (type-from-parent n)
            (assq-ref parent-snapshot-locals (if (<= 0 initial-offset)
                                                 n
                                                 (- n initial-offset))))
          (let lp ((vars (reverse vars)))
            (match vars
              (((n . var) . vars)
               (debug 3 ";;;   n:~a~%" n)
               (debug 3 ";;;   var: ~a~%" var)
               (debug 3 ";;;   from parent: ~a~%" (type-from-parent n))
               (debug 3 ";;;   from snapshot: ~a~%" (type-from-snapshot n))
               (cond
                ;; When local was passed from parent and snapshot 0 contained
                ;; the local with same type, no need to load from frame. If type
                ;; does not match, the value passed from parent has different
                ;; was untagged with different type, reload from frame.
                ;;
                ;; When locals index was found in parent snapshot locals and not
                ;; from snapshot 0 of this trace, the local will be passed from
                ;; parent fragment, ignoreing.
                ;;
                ;; If initial offset is positive and local index is negative,
                ;; locals from lower frame won't be passed as argument. Loading
                ;; later with '%fref' or '%fref/f'.
                ;;
                ((let ((parent-type (type-from-parent n))
                       (snapshot-type (type-from-snapshot n)))
                   (or (and parent-type
                            snapshot-type
                            (eq? parent-type snapshot-type))
                       (and (not snapshot-type)
                            parent-type)
                       (and (<= 0 initial-offset)
                            (< n 0))))
                 (lp vars))
                (else
                 (let* ((i (- n (snapshot-offset snapshot0)))
                        (local (if (and (< -1 i)
                                        (< i (vector-length initial-locals)))
                                   (vector-ref initial-locals i)
                                   (make-variable #f)))
                        (type (type-of local)))
                   (debug 3 ";;; add-initial-loads: n=~a~%" n)
                   (debug 3 ";;;   local:          ~a~%" local)
                   (debug 3 ";;;   type:           ~a~%" type)

                   ;; Shift the index when this trace started from negative
                   ;; offset. Skip loading from frame when shifted index is
                   ;; negative, should be loaded explicitly with `%fref' or
                   ;; `%fref/f'.
                   (let ((j (if (< initial-offset 0)
                                (- n initial-offset)
                                n)))
                     (if (< j 0)
                         (lp vars)
                         (with-frame-ref lp vars var type j)))))))
              (()
               exp-body)))))

      (define (make-scm escape trace)
        (let ((do-compile
               (lambda ()
                 (compile-ir trace escape loop? snapshot-id snapshots
                             parent-snapshot past-frame vars))))
          (cond
           (root-trace?
            (let* ((snapshot (make-snapshot 0 0 0 initial-nlocals initial-locals
                                            #f (reverse local-indices)
                                            past-frame initial-ip))
                   (_ (hashq-set! snapshots 0 snapshot))
                   (snap (take-snapshot! *ip-key-set-loop-info!*
                                         0 initial-locals vars)))
              `(letrec ((entry (lambda ()
                                 (let ((_ (%snap 0)))
                                   ,(add-initial-loads
                                     `(let ((_ ,snap))
                                        (loop ,@args))))))
                        (loop (lambda ,args
                                ,(do-compile))))
                 entry)))
           (loop?
            (let ((args-from-vars (reverse! (map cdr vars)))
                  (snap (take-snapshot! initial-ip 0 initial-locals
                                        vars-from-parent)))
              `(letrec ((entry (lambda ,args-from-parent
                                 (let ((_ ,snap))
                                   ,(add-initial-loads
                                     `(loop ,@args-from-vars)))))
                        (loop (lambda ,args-from-vars
                                ,(do-compile))))
                 entry)))
           (else
            (let ((snap (take-snapshot! initial-ip 0 initial-locals
                                        vars-from-parent)))
              `(letrec ((patch (lambda ,args-from-parent
                                 (let ((_ ,snap))
                                   ,(add-initial-loads
                                     (do-compile))))))
                 patch))))))

      (let ((scm (call-with-escape-continuation
                  (lambda (escape)
                    (make-scm escape trace)))))
        (debug 3 ";;; snapshot:~%~{;;;   ~a~%~}"
               (sort (hash-fold acons '() snapshots)
                     (lambda (a b) (< (car a) (car b)))))
        (let ((indices (if root-trace?
                           local-indices
                           local-indices-from-parent)))
          (values indices vars snapshots scm))))))

(define (trace->primlist trace-id fragment exit-id loop? trace)
  "Compiles TRACE to primlist.

If the trace to be compiles is a side trace, expects FRAGMENT as from parent
trace, and EXIT-ID is the hot exit id from the parent trace. LOOP? is a boolean
to indicate whether the trace contains loop or not."
  (when (tjit-dump-time? (tjit-dump-option))
    (let ((log (get-tjit-time-log trace-id)))
      (set-tjit-time-log-scm! log (get-internal-run-time))))
  (let-values (((locals vars snapshots scm)
                (trace->scm fragment exit-id loop? trace)))
    (when (tjit-dump-time? (tjit-dump-option))
      (let ((log (get-tjit-time-log trace-id)))
        (set-tjit-time-log-ops! log (get-internal-run-time))))
    (let* ((parent-snapshot (and fragment
                                 (hashq-ref (fragment-snapshots fragment)
                                            exit-id)))
           (initial-snapshot (hashq-ref snapshots 0))
           (plist (and scm
                       (anf->primlist parent-snapshot initial-snapshot
                                      vars scm))))
      (values locals snapshots scm plist))))
