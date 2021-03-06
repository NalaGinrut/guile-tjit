;;; Same procedure definitions with `t-flonum-04', but argument passed
;;; to `mandelbrot-main' is different, which result to different
;;; recorded bytecode in trace 1.

(define *bailout* 16.0)
(define *max-iterations* 1000)

(define (mandelbrot x y)
  (let ((cr (- y 0.5))
        (ci x)
        (zi 0.0)
        (zr 0.0))
    (let lp ((i 0) (zr zr) (zi zi))
      (if (< *max-iterations* i)
          0
          (let ((zi2 (* zi zi))
                (zr2 (* zr zr)))
            (if (< *bailout* (+ zi2 zr2))
                i
                (lp (+ i 1)
                    (+ (- zr2 zi2) cr)
                    (+ (* 2.0 zr zi) ci))))))))

(define (mandelbrot-main size)
  (let loop ((y (- (- size 1))) (acc '()))
    (if (not (= y (- size 1)))
        (let ((line
               (let loop ((x (- (- size 1))) (output '()))
                 (if (= x (- size 1))
                     (list->string output)
                     (let* ((fx (/ x (exact->inexact size)))
                            (fy (/ y (exact->inexact size)))
                            (c (if (zero? (mandelbrot fx fy))
                                   #\*
                                   #\space)))
                       (loop (+ x 1) (cons c output)))))))
          (loop (+ y 1) (cons line acc)))
        (reverse! acc))))

(mandelbrot-main 38)
