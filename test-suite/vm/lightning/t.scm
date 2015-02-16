;;; Copyright (C) 2014, 2015 Free Software Foundation, Inc.
;;;
;;; This library is free software; you can redistribute it and/or
;;; modify it under the terms of the GNU Lesser General Public
;;; License as published by the Free Software Foundation; either
;;; version 3 of the License, or (at your option) any later version.
;;;
;;; This library is distributed in the hope that it will be useful,
;;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;;; Lesser General Public License for more details.
;;;
;;; You should have received a copy of the GNU Lesser General Public
;;; License along with this library; if not, write to the Free Software
;;; Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA
;;; 02110-1301 USA

;;; Commentary:

;;; Tests for vm-lightning

;;; Code:

(use-modules (srfi srfi-64)
             (system vm program)
             (system vm lightning)
             (system vm vm))

;; Define and run a procedure with guile vm and lightning, and compare the
;; results with test-equal.
(define-syntax define-test
  (syntax-rules ()
    ((_ (name . vars) args body ...)
     (begin
       (define (name . vars)
         body ...)
       (test-equal (symbol->string (procedure-name name))
         (name . args)
         (call-lightning name . args))))))

;;;
;;; VM operation
;;;

(test-begin "vm-lightning-test")

;;; Call and return

(define (callee x)
  (+ 1 x))

(define-test (l-call n) (98)
  (+ 1 (callee n)))

(define-test (l-call-simple-prim x y) ('(a b c) '(d e f g h))
  (+ (length x) (length y)))

(define-test (l-call-arg0 f x) ((lambda (a) (+ a 100)) 23)
  (f x))

(define (add-one x)
  (+ x 1))

(define-test (l-my-map f xs) (add-one '(1 2 3))
  (let lp ((xs xs))
    (if (null? xs)
        '()
        (cons (f (car xs)) (l-my-map f (cdr xs))))))

(define (my-map f xs)
  (let lp ((xs xs))
    (if (null? xs)
        '()
        (cons (f (car xs)) (my-map f (cdr xs))))))

(define-test (call-my-map xs) ('(1 2 3 4 5))
  (my-map add-one xs))

(define (make-applicable-struct)
  (make-procedure-with-setter
   (lambda (obj)
     (+ obj 1))
   (lambda (obj val)
     (list obj val))))

(define applicable-struct (make-applicable-struct))

(define-test (call-applicable-struct n) (99)
  (applicable-struct n))

;;; Specialized call stubs

;;; Function prologues

(define-test (l-identity x) (12345)
  x)

;;; Branching instructions

(define-test (l-if-zero x) (0)
  (if (zero? x)
      100
      200))

(define-test (l-if-null x) ('(1 2 3))
  (if (null? x)
      100
      200))

(define-test (l-if-true x) (#t)
  (if x 100 200))

(define-test (l-if-true-invert x) (#t)
  (if (not x) 100 200))

;;; Lexical binding instructions

(define-test (l-box-set! n) (20)
  (let ((result 0))
    (if (< n 100)
        (set! result n)
        (set! result 0))
    result))

(define (closure01 x)
  (lambda (y)
    (+ x y)))

(test-equal "closure01-program-code"
  (program-code (closure01 100))
  (program-code (call-lightning closure01 100)))

(let ((closure01-vm (closure01 23))
      (closure01-lightning (call-lightning closure01 23)))

  (test-equal "closure01-call-01"
    (closure01-vm 100)
    (call-lightning closure01-vm 100))

  (test-equal "closure01-call-02"
    (closure01-vm 100)
    (call-lightning closure01-lightning 100))

  (test-equal "closure01-call-03"
    (closure01-vm 100)
    (closure01-lightning 100)))

(define-test (closure02 x) (23)
  ((closure01 x) 100))

(define (closure03 n)
  (lambda ()
    (+ n 1)))

(define-test (call-closure03 x) (23)
  ((closure03 (+ ((closure03 x))
                 ((closure03 10))))))

(define-test (call-closure03-b x) (12345)
  (cons ((closure03 (+ x 100))) 23))

(define (closure04 n)
  (lambda ()
    (let lp ((n n) (acc 0))
      (if (< n 0)
          acc
          (lp (- n 1) (+ acc n))))))

(define-test (call-closure04 n) (100)
  ((closure04 n)))

(define (addk x y k)
  (k (+ x y)))

(define (mulk x y k)
  (k (* x y)))

(define-test (muladdk x y z k) (3 4 5 (lambda (a) a))
  (mulk x y
        (lambda (xy)
          (addk xy z k))))

(test-skip 1)
(define-test (pythk2 x y k) (3 4 (lambda (a) a))
  (mulk x x
        (lambda (x2)
          (mulk y y
                (lambda (y2)
                  (addk x2 y2 k))))))

;;; Immediates and statically allocated non-immediates

(define-test (l-make-short-immediate) () ;; no args.
  100)

(define-test (l-long-long-immediate) ()
  -12345)

(define-test (l-non-immediate) ()
  "non-immediate string.")

(define-test (l-static-ref) ()
  0.5)

;;; Mutable top-level bindings

(define a-toplevel-ref 123)

(define-test (l-toplevel-box x) (321)
  (+ x a-toplevel-ref))

(define (add-toplevel-ref x)
  (+ x a-toplevel-ref))

;; Call a function with toplevel-box twice. In first call, variable need to be
;; resolved.  In second call, variable should be already stored. Writing test
;; without using define-test macro. The macro runs bytecode procedure first, and
;; variable get cached when bytecode procedure runs.
(test-equal "resolve-toplevel-var"
  (call-lightning add-toplevel-ref 100)
  (call-lightning add-toplevel-ref 100))

(define-test (l-module-box) ()
  length)

(define (get-from-module-box)
  length)

(test-equal "resolve-module-box-var"
  'length
  (procedure-name (call-lightning get-from-module-box)))

;;; The dynamic environment

;;; String, symbols, and keywords

(define-test (l-string-length str) ("foo-bar-buzz")
  (string-length str))

;;; Pairs

(define-test (l-car x) ('(foo bar buzz))
  (car x))

(define-test (l-cdr x) ('(foo bar buzz))
  (cdr x))

(define-test (l-cons x y) (100 200)
  (cons x y))

;;; Numeric operations

(define-test (l-add1 x) (99)
  (+ 1 x))

(define-test (l-add-fx-fx x y) (27 73)
  (+ x y))

(define-test (l-add-fx-fl x y) (3 0.456)
  (+ x y))

(define-test (l-add-fl-fx x y) (0.345 4)
  (+ x y))

(define-test (l-add-fl-fl x y) (0.125 0.775)
  (+ x y))

(define-test (l-add-fx-gmp x y)
  (9999999999999999999999999999999 999999999999999999999999999999)
  (+ x y))

(define-test (l-add-overflow x y) ((- (expt 2 61) 1) 100)
  (+ x y))

(define-test (l-sub x y) (127 27)
  (- x y))

(define-test (l-mul x y) (123 321)
  (* x y))

(define-test (l-div x y) (32 8)
  (/ x y))


;;; Structs and GOOPS

;;; Arrays, packed uniform arrays, and bytevectors

;;;
;;; Simple procedures
;;;

(define-test (l-lp n) (#e1e7)
  (let lp ((n n))
    (if (< 0 n) (lp (- n 1)) n)))

(define-test (l-sum-tail-call x) (1000)
  (let lp ((n x) (acc 0))
    (if (< n 0)
        acc
        (lp (- n 1) (+ acc n)))))

(define-test (l-sum-non-tail-call x) (1000)
  (let lp ((n x))
    (if (< n 0)
        0
        (+ n (lp (- n 1))))))

(define-test (l-sum-toplevel n acc) (1000 0)
  (if (= n 0)
      acc
      (l-sum-toplevel (- n 1) (+ n acc))))

(test-skip 1)
(define-test (l-sum-cps n k) (10 (lambda (a) a))
  (if (< n 0)
      (k 0)
      (l-sum-cps (- n 1)
                 (lambda (s)
                   (k (+ s n))))))

(define-test (fib1 n) (30)
  (let lp ((n n))
    (if (< n 2)
        n
        (+ (lp (- n 1))
           (lp (- n 2))))))

(define-test (fib2 n) (30)
  (if (< n 2)
      n
      (+ (fib2 (- n 1))
         (fib2 (- n 2)))))

(define-test (nqueens n) (8)
  (define (my-append a b)
    (if (null? a)
        b
        (cons (car a) (my-append (cdr a) b))))
  (define (one-to n)
    (let loop ((i n) (l '()))
      (if (= i 0) l (loop (- i 1) (cons i l)))))
  (define (ok? row dist placed)
    (if (null? placed)
        #t
        (and (not (= (car placed) (+ row dist)))
             (not (= (car placed) (- row dist)))
             (ok? row (+ dist 1) (cdr placed)))))
  (define (try-it x y z)
    (if (null? x)
        (if (null? y) 1 0)
        (+ (if (ok? (car x) 1 z)
               (try-it (my-append (cdr x) y) '() (cons (car x) z))
               0)
           (try-it (cdr x) (cons (car x) y) z))))
  (try-it (one-to n) '() '()))

(define-test (tak x y z) (18 12 6)
  (if (not (< y x))
      z
      (tak (tak (- x 1) y z)
           (tak (- y 1) z x)
           (tak (- z 1) x y))))

(test-end "vm-lightning-test")
