(in-package #:coalton-tests)

(defun run-coalton-tests ()
  (run-package-tests
   :packages '(:coalton-tests
               :quil-coalton-tests
               :thih-coalton/fiasco-test-package)
   :interactive t))

(defun set-equalp (set1 set2)
  (null (set-exclusive-or set1 set2 :test #'equalp)))

(defun dag-equalp (dag1 dag2)
  ;; XXX: This will not check ordering of edges within vertices
  (set-equalp dag1 dag2))

(defun check-string= (context a b)
  "Signal a test failure assertion if strings A and B differ, reporting the first position at which this is true."
  (let ((compare-len (min (length a)
                          (length b))))
    (loop :for i :from 0 :below compare-len
          :unless (char= (aref a i)
                         (aref b i))
            :do (is (string= a b)
                    (format nil "Strings differ at offset ~A of ~A:~%A: ~A~%B: ~A"
                            i context a b))
                (return-from check-string=))
    (is (= (length a)
           (length b))
        (format nil "Strings differ at offset ~A of ~A:~%~A~%~A"
                compare-len context a b))))

(defun check-coalton-types (toplevel-string &rest expected-types)
  (let ((*package* (make-package (or (and fiasco::*current-test*
                                          (fiasco::name-of fiasco::*current-test*))
                                     "COALTON-TEST-COMPILE-PACKAGE")
                                 :use '("COALTON" "COALTON-PRELUDE"))))
    (unwind-protect
         (let ((source (source:make-source-string toplevel-string)))
           (with-open-stream (stream (se:source-stream source))
             (let ((program (parser:with-reader-context stream
                              (parser:read-program stream source))))

               (multiple-value-bind (program env)
                   (entry:entry-point program)
                 (declare (ignore program))
 
                 (when expected-types
                   (loop :for (unparsed-symbol . unparsed-type) :in expected-types
                         :do (let ((symbol (intern (string-upcase unparsed-symbol) *package*))
                                   (source (source:make-source-string unparsed-type)))
                               (with-open-stream (stream (se:source-stream source))
                                 (let* ((ast-type (parser:parse-qualified-type
                                                   (eclector.concrete-syntax-tree:read stream)
                                                   source))
                                        (parsed-type (tc:parse-ty-scheme ast-type env)))
                                   (is (equalp
                                        (tc:lookup-value-type env symbol)
                                        parsed-type))))))))))
           (values))
      (delete-package *package*))))

(defun compile-and-load-forms (coalton-forms)
  "Write the COALTON-FORMS to a temporary file, compile it to a fasl, then load the compiled file.

Returns (values SOURCE-PATHNAME COMPILED-PATHNAME)."
  (uiop:with-temporary-file (:stream out-stream
                             :pathname input-file
                             :suffix "lisp"
                             :direction :output
                             :keep t)
    (dolist (expr coalton-forms)
      (prin1 expr out-stream)
      (terpri out-stream))
    :close-stream
    (uiop:with-temporary-file (:pathname output-file
                               :type #+ccl (pathname-type ccl:*.fasl-pathname*)
                                     #+(not ccl) "fasl"
                               :keep t)
      (compile-file input-file :output-file output-file)
      (load output-file)
      (values input-file output-file))))

(defmacro with-coalton-compilation ((&key package (muffle 'cl:style-warning)) &body coalton-code)
  `(handler-bind
       ((,muffle #'muffle-warning))
     (compile-and-load-forms '(,@(when package `((cl:in-package ,package)))
                               ,@coalton-code))))

(defun test-file (pathname)
  "Create a pathname relative to the coalton/test system."
  (merge-pathnames pathname (asdf:system-source-directory "coalton/tests")))

(defun collect-compiler-error (program)
  (let ((source (source:make-source-string program :name "test")))
    (handler-case
        (progn
          (entry:compile source)
          nil)
      (se:source-base-error (c)
        (string-trim '(#\Space #\Newline)
                     (princ-to-string c))))))

(defun run-suite (pathname)
  (let ((file (test-file pathname)))
    (loop :for (line description program expected-error)
            :in (coalton-tests/loader:load-suite file)
          :for generated-error := (collect-compiler-error program)
          :do (cond ((null generated-error)
                     (is (zerop (length expected-error))
                         "program should have failed to compile: ~A" description))
                    (t
                     (check-string= (format nil "program text.~%~
input file: ~A~%~
line number: ~A~%~
test case: ~A~%~
expected error (A) and generated error (B)"
                                            file line description)
                                    expected-error
                                    generated-error))))))
