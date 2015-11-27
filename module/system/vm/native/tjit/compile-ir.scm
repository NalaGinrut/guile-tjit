;;;; Bytecode to IR compiler

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
;;; Compile list of bytecode operations to intermediate representation (IR) in
;;; (almost) A-normal form (ANF).
;;;
;;; One of the main reasons to convert bytecode to ANF is to do floating point
;;; arithmetic efficiently. VM bytecodes uses integer index to refer locals, and
;;; those locals does not distinguish floating point values from other. In ANF
;;; format, it is possible to perform floating point arithmetic directly with
;;; unboxed value in floating point register inside loop.
;;;
;;; Code:

(define-module (system vm native tjit compile-ir)
  #:use-module (ice-9 control)
  #:use-module (ice-9 format)
  #:use-module (ice-9 match)
  #:use-module (language scheme spec)
  #:use-module (rnrs bytevectors)
  #:use-module (srfi srfi-11)
  #:use-module (system base compile)
  #:use-module (system foreign)
  #:use-module (system vm native debug)
  #:use-module (system vm native tjit fragment)
  #:use-module (system vm native tjit ir)
  #:use-module (system vm native tjit parameters)
  #:use-module (system vm native tjit ra)
  #:use-module (system vm native tjit snapshot)
  #:export (trace->primlist))


;;;
;;; Traced bytecode to ANF IR compiler
;;;

(define (trace->ir traces escape loop? downrec?
                   initial-snapshot-id snapshots
                   parent-snapshot past-frame vars
                   initial-sp-offset initial-fp-offset handle-interrupts?)
  (let* ((bytecode-index (make-variable 0))
         (min-sp-offset (make-variable (min initial-sp-offset 0)))
         (initial-nlocals (snapshot-nlocals (hashq-ref snapshots 0)))
         (max-sp-offset (make-variable (get-max-sp-offset initial-sp-offset
                                                          initial-fp-offset
                                                          initial-nlocals)))
         (last-sp-offset (let* ((sp-offsets (past-frame-sp-offsets past-frame))
                                (i (- (vector-length sp-offsets) 1)))
                           (vector-ref sp-offsets i)))
         (last-fp-offset (let* ((fp-offsets (past-frame-fp-offsets past-frame))
                                (i (- (vector-length fp-offsets) 1)))
                           (vector-ref fp-offsets i)))
         (snapshot-id (make-variable initial-snapshot-id)))
    (define (take-snapshot-with-locals! ip dst-offset locals sp-offset min-sp)
      (let-values (((ret snapshot)
                    (take-snapshot ip
                                   dst-offset
                                   locals
                                   vars
                                   (variable-ref snapshot-id)
                                   sp-offset
                                   last-fp-offset
                                   min-sp
                                   (variable-ref max-sp-offset)
                                   parent-snapshot
                                   past-frame)))
        (let* ((old-snapshot-id (variable-ref snapshot-id))
               (new-snapshot-id (+ old-snapshot-id 1)))
          (hashq-set! snapshots old-snapshot-id snapshot)
          (variable-set! snapshot-id new-snapshot-id)
          ret)))
    (define (convert-one op ip ra locals rest)
      (cond
       ((hashq-ref *ir-procedures* (car op))
        => (lambda (proc)
             (let ((next
                    (lambda ()
                      (let* ((old-index (variable-ref bytecode-index))
                             (sp-offsets (past-frame-sp-offsets past-frame))
                             (sp-offset (vector-ref sp-offsets old-index))
                             (fp-offsets (past-frame-fp-offsets past-frame))
                             (fp-offset (vector-ref fp-offsets old-index))
                             (nlocals (vector-length locals))
                             (max-offset (get-max-sp-offset sp-offset
                                                            fp-offset
                                                            nlocals)))
                        (variable-set! bytecode-index (+ 1 old-index))
                        (when (< sp-offset (variable-ref min-sp-offset))
                          (variable-set! min-sp-offset sp-offset))
                        (when (< (variable-ref max-sp-offset) max-offset)
                          (variable-set! max-sp-offset max-offset)))
                      (convert rest))))
               (apply proc
                      snapshots
                      snapshot-id
                      parent-snapshot
                      past-frame
                      locals
                      vars
                      min-sp-offset
                      max-sp-offset
                      ip
                      ra
                      handle-interrupts?
                      bytecode-index
                      next
                      escape
                      (cdr op)))))
       (else
        (debug 2 "*** IR: NYI ~a~%" (car op))
        (escape #f))))
    (define (convert trace)
      ;; Last operation is wrapped in a thunk, to assign snapshot ID
      ;; in last expression after taking snapshots from guards in
      ;; traced operations.
      ;;
      ;; Trace with loop will emit `loop', which is the name of
      ;; procedure for looping the body of Scheme IR emitted in
      ;; `make-scm'.
      ;;
      ;; Side trace or loop-less root trace are capturing variables
      ;; with `take-snapshot!' at the end, so that the machine code
      ;; can pass the register information to linked code.
      ;;
      (define (gen-last-op op ip ra locals)
        (define (downrec-locals proc nlocals)
          (let lp ((n 0) (end (vector-length locals)) (acc '()))
            (if (= n nlocals)
                (list->vector acc)
                (let* ((i (- end proc n 1))
                       (e (vector-ref locals i)))
                  (lp (+ n 1) end (cons e acc))))))
        (cond
         (downrec?
          (match op
            (('call proc nlocals)
             (lambda ()
               (let* ((initial-snapshot (hashq-ref snapshots 0))
                      (initial-nlocals (snapshot-nlocals initial-snapshot))
                      (next-sp (- last-fp-offset proc nlocals))
                      (next-sp-offset (+ next-sp initial-nlocals)))
                 `(let ((_ ,(take-snapshot-with-locals!
                             *ip-key-downrec*
                             0
                             (downrec-locals proc nlocals)
                             next-sp-offset
                             next-sp-offset)))
                    (loop ,@(reverse (map cdr vars)))))))
            (('call-label . _)
             ;; XXX: TODO.
             (escape #f))
            (_
             (escape #f))))
         (loop?
          (lambda ()
            `(loop ,@(reverse (map cdr vars)))))
         (else
          (lambda ()
            `(let ((_ ,(take-snapshot-with-locals!
                        *ip-key-jump-to-linked-code*
                        0
                        locals
                        last-sp-offset
                        (variable-ref min-sp-offset))))
               _)))))
      (match trace
        (((op ip ra locals) . ())
         (let ((last-op (gen-last-op op ip ra locals)))
           (convert-one op ip ra locals last-op)))
        (((op ip ra locals) . rest)
         (convert-one op ip ra locals rest))
        (last-op
         (or (and (procedure? last-op)
                  (last-op))
             (error "trace->ir: last arg was not a procedure" last-op)))))

    (convert traces)))

(define (compile-ir fragment exit-id loop? downrec? trace)
  (define-syntax root-trace?
    (identifier-syntax (not fragment)))
  (define (get-initial-snapshot-id)
    ;; For root trace, initial snapshot already added in `make-ir'.
    (if root-trace? 1 0))
  (define (get-initial-sp-offset parent-snapshot)
    ;; Initial offset of root trace is constantly 0. Initial offset of side
    ;; trace is where parent trace left, using offset value from SNAPSHOT.
    (match parent-snapshot
      (($ $snapshot _ sp-offset) sp-offset)
      (_ 0)))
  (define (get-initial-fp-offset parent-snapshot)
    ;; Initial offset of root trace is constantly 0. Initial offset of side
    ;; trace is where parent trace left, using offset value from SNAPSHOT.
    (match parent-snapshot
      (($ $snapshot _ _ fp-offset) fp-offset)
      (_ 0)))

  (let* ((parent-snapshot
          (and fragment
               (hashq-ref (fragment-snapshots fragment) exit-id)))
         (initial-sp-offset (get-initial-sp-offset parent-snapshot))
         (initial-fp-offset (get-initial-fp-offset parent-snapshot))
         (past-frame (accumulate-locals initial-sp-offset
                                        initial-fp-offset
                                        trace))
         (local-indices (past-frame-local-indices past-frame))
         (vars (make-vars local-indices))
         (lowest-offset (min initial-sp-offset 0))
         (snapshots (make-hash-table))
         (snapshot-id (get-initial-snapshot-id)))

    (define (take-snapshot! ip dst-offset locals vars)
      (let*-values (((ret snapshot)
                     (take-snapshot ip
                                    dst-offset
                                    locals vars
                                    snapshot-id
                                    initial-sp-offset
                                    initial-fp-offset
                                    lowest-offset
                                    (get-max-sp-offset initial-sp-offset
                                                       initial-fp-offset
                                                       (vector-length locals))
                                    parent-snapshot
                                    past-frame)))
        (hashq-set! snapshots snapshot-id snapshot)
        (set! snapshot-id (+ snapshot-id 1))
        ret))

    (define (make-vars-from-parent vars
                                   locals-from-parent
                                   sp-offset-from-parent)
      (let lp ((vars vars) (acc '()))
        (match vars
          (((n . var) . vars)
           (if (assq-ref locals-from-parent n)
               (lp vars (cons (cons n var) acc))
               (lp vars acc)))
          (()
           (reverse! acc)))))

    (let* ((args (map make-var (reverse local-indices)))
           (initial-trace (car trace))
           (initial-ip (cadr initial-trace))
           (initial-locals (cadddr initial-trace))
           (initial-nlocals (vector-length initial-locals))
           (parent-snapshot-locals (match parent-snapshot
                                     (($ $snapshot _ _ _ _ locals) locals)
                                     (_ #f)))
           (vars-from-parent (make-vars-from-parent vars
                                                    parent-snapshot-locals
                                                    initial-sp-offset))
           (args-from-parent (reverse (map cdr vars-from-parent)))
           (local-indices-from-parent (map car vars-from-parent))
           (handle-interrupts? (make-variable #f)))

      (define (add-initial-loads exp-body)
        (debug 3 ";;; add-initial-loads:~%")
        (debug 3 ";;;   initial-locals=~a~%" initial-locals)
        (debug 3 ";;;   parent-snapshot-locals=~a~%" parent-snapshot-locals)
        (let ((snapshot0 (hashq-ref snapshots 0)))
          (define (type-from-snapshot n)
            (let ((i (- n (snapshot-sp-offset snapshot0))))
              (and (< -1 i (vector-length initial-locals))
                   (type-of (vector-ref initial-locals i)))))
          (define (type-from-parent n)
            (assq-ref parent-snapshot-locals n))
          (let lp ((vars (reverse vars)))
            (match vars
              (((n . var) . vars)
               (debug 3 ";;; add-initial-loads: n=~a~%" n)
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
                   (and (not loop?)
                        (or (and parent-type
                                 snapshot-type
                                 (eq? parent-type snapshot-type))
                            (and (not snapshot-type)
                                 parent-type)
                            (and (<= 0 initial-sp-offset)
                                 (< n 0)))))
                 (lp vars))
                ((let ((i (- n (snapshot-sp-offset snapshot0))))
                   (not (< -1 i (vector-length initial-locals))))
                 (lp vars))
                (else
                 (let* ((i (- n (snapshot-sp-offset snapshot0)))
                        (local (vector-ref initial-locals i))
                        (type (type-of local)))
                   (debug 3 ";;;   local:          ~a~%" local)
                   (debug 3 ";;;   type:           ~a~%" type)

                   ;; Shift the index when this trace started from negative
                   ;; offset. Skip loading from frame when shifted index is
                   ;; negative, should be loaded explicitly with `%fref' or
                   ;; `%fref/f'.
                   (let ((j (+ n initial-sp-offset)))
                     (if (< j 0)
                         (lp vars)
                         (with-frame-ref lp vars var type j)))))))
              (()
               exp-body)))))

      (define (make-ir escape)
        (let ((emit (lambda ()
                      (trace->ir trace
                                 escape
                                 loop?
                                 downrec?
                                 snapshot-id
                                 snapshots
                                 parent-snapshot
                                 past-frame
                                 vars
                                 initial-sp-offset
                                 initial-fp-offset
                                 handle-interrupts?))))
          (cond
           (root-trace?
            (let* ((arg-indices (filter (lambda (n)
                                          (<= 0 n))
                                        (reverse local-indices)))
                   (snapshot (make-snapshot 0
                                            0
                                            0
                                            0
                                            initial-nlocals
                                            initial-locals
                                            #f
                                            arg-indices
                                            past-frame
                                            initial-ip))
                   (_ (hashq-set! snapshots 0 snapshot))
                   (snap (take-snapshot! *ip-key-set-loop-info!*
                                         0
                                         initial-locals
                                         vars)))
              `(letrec ((entry (lambda ()
                                 (let ((_ (%snap 0)))
                                   ,(add-initial-loads
                                     `(let ((_ ,snap))
                                        (loop ,@args))))))
                        (loop (lambda ,args
                                ,(emit))))
                 entry)))
           (loop?
            (let ((args-from-vars (reverse! (map cdr vars)))
                  (snap (take-snapshot! initial-ip
                                        0
                                        initial-locals
                                        vars-from-parent)))
              `(letrec ((entry (lambda ,args-from-parent
                                 (let ((_ ,snap))
                                   ,(add-initial-loads
                                     `(loop ,@args-from-vars)))))
                        (loop (lambda ,args-from-vars
                                ,(emit))))
                 entry)))
           (else
            (let ((snap (take-snapshot! initial-ip
                                        0
                                        initial-locals
                                        vars-from-parent)))
              `(letrec ((patch (lambda ,args-from-parent
                                 (let ((_ ,snap))
                                   ,(add-initial-loads
                                     (emit))))))
                 patch))))))

      (let ((ir (call-with-escape-continuation make-ir)))
        (debug 3 ";;; snapshot:~%~{;;;   ~a~%~}"
               (sort (hash-fold acons '() snapshots)
                     (lambda (a b) (< (car a) (car b)))))
        (let ((indices (if root-trace?
                           local-indices
                           local-indices-from-parent)))
          (values indices vars snapshots ir
                  (variable-ref handle-interrupts?)))))))

(define (trace->primlist trace-id fragment exit-id loop? downrec? trace)
  "Compiles TRACE to primlist.

If the trace to be compiles is a side trace, expects FRAGMENT as from parent
trace, and EXIT-ID is the hot exit id from the parent trace. LOOP? is a boolean
to indicate whether the trace contains loop or not."
  (when (tjit-dump-time? (tjit-dump-option))
    (let ((log (get-tjit-time-log trace-id)))
      (set-tjit-time-log-scm! log (get-internal-run-time))))
  (let-values (((locals vars snapshots ir handle-interrupts?)
                (compile-ir fragment exit-id loop? downrec? trace)))
    (when (tjit-dump-time? (tjit-dump-option))
      (let ((log (get-tjit-time-log trace-id)))
        (set-tjit-time-log-ops! log (get-internal-run-time))))
    (let* ((parent-snapshot (and fragment
                                 (hashq-ref (fragment-snapshots fragment)
                                            exit-id)))
           (initial-snapshot (hashq-ref snapshots 0))
           (primlist (if ir
                         (ir->primlist parent-snapshot
                                       initial-snapshot
                                       vars
                                       handle-interrupts?
                                       snapshots
                                       ir)
                         #f)))
      (values locals snapshots ir primlist))))
