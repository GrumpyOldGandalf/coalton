(defpackage #:coalton-impl/analysis/analysis
  (:use
   #:cl
   #:coalton-impl/typechecker/base
   #:coalton-impl/analysis/pattern-exhaustiveness)
  (:import-from
   #:coalton-impl/analysis/unused-variables
   #:find-unused-variables)
  (:import-from
   #:coalton-impl/analysis/underapplied-values
   #:find-underapplied-values)
  (:local-nicknames
   (#:se #:source-error)
   (#:source #:coalton-impl/source)
   (#:util #:coalton-impl/util)
   (#:tc #:coalton-impl/typechecker))
  (:export
   #:analyze-translation-unit))

(in-package #:coalton-impl/analysis/analysis)

(define-condition non-exhaustive-match-warning (se:source-base-warning)
  ())

(define-condition useless-pattern-warning (se:source-base-warning)
  ())

(define-condition pattern-var-matches-constructor (se:source-base-warning)
  ())

(defun check-pattern-exhaustiveness (pattern env)
  (declare (type tc:pattern pattern)
           (type tc:environment env))

  (let ((missing (find-non-matching-value (list (list pattern)) 1 env)))
    (unless (eq t missing)
      (tc-error (tc:pattern-location pattern)
                "Non-exhaustive match"
                (format nil "Missing case ~W"
                        (print-pattern (first missing)))))))

(defun analyze-translation-unit (translation-unit env)
  "Perform analysis passes on TRANSLATION-UNIT, potentially producing errors or warnings."
  (declare (type tc:translation-unit translation-unit)
           (type tc:environment env))

  (let ((analysis-traverse-block
          (tc:make-traverse-block
           :match (lambda (node)
                    (let ((patterns (mapcar #'tc:node-match-branch-pattern (tc:node-match-branches node))))
                      (loop :for pattern :in patterns
                            :do (check-for-var-matching-constructor pattern env))

                      (let ((exhaustive-or-missing
                              (find-non-matching-value (mapcar #'list patterns) 1 env)))
                        (unless (eq t exhaustive-or-missing)
                          (warn 'non-exhaustive-match-warning
                                :err (source:source-error
                                      :type :warn
                                      :location (tc:node-location node)
                                      :message "Non-exhaustive match"
                                      :primary-note "non-exhaustive match"
                                      :notes (when (first exhaustive-or-missing)
                                               (list
                                                (se:make-source-error-note
                                                 :type :secondary
                                                 :span (source:location-span (tc:node-location node))
                                                 :message (format nil "Missing case ~W"
                                                                  (print-pattern (first exhaustive-or-missing)))))))))
                        (loop :for pattern :in patterns
                              :unless (useful-pattern-p patterns pattern env) :do
                                (warn 'useless-pattern-warning
                                      :err (source:source-error
                                            :type :warn
                                            :location (tc:pattern-location pattern)
                                            :message "Useless match case"
                                            :primary-note "useless match case"
                                            :notes
                                            (list
                                             (se:make-source-error-note
                                              :type :secondary
                                              :span (source:location-span (tc:node-location node))
                                              :message "in this match")))))))
                    node)
           :abstraction (lambda (node)
                          (declare (type tc:node-abstraction node))
                          (loop :for pattern :in (tc:node-abstraction-params node)
                                :do (check-pattern-exhaustiveness pattern env))
                          node)
           :bind (lambda (node)
                   (declare (type tc:node-bind node))
                   (check-pattern-exhaustiveness (tc:node-bind-pattern node) env)
                   node))))

    ;; Run analysis on definitions
    (loop :for define :in (tc:translation-unit-definitions translation-unit)
          :do (tc:traverse (tc:toplevel-define-body define) analysis-traverse-block)
          :do (find-unused-variables define)
          :do (find-underapplied-values define)
          :do (loop :for pattern :in (tc:binding-parameters define)
                    :do (check-pattern-exhaustiveness pattern env)))

    ;; Run analysis on instance definitions
    (loop :for instance :in (tc:translation-unit-instances translation-unit) :do
      (loop :for method :being :the :hash-value :of (tc:toplevel-define-instance-methods instance)
            :do (tc:traverse (tc:instance-method-definition-body method) analysis-traverse-block)
            :do (find-underapplied-values method)
            :do (find-underapplied-values method)
            :do (loop :for pattern :in (tc:binding-parameters method)
                      :do (check-pattern-exhaustiveness pattern env))))))

(defgeneric print-pattern (pat)
  (:method ((pat tc:pattern-constructor))
    (cons (tc:pattern-constructor-name pat) (mapcar #'print-pattern (tc:pattern-constructor-patterns pat))))

  (:method ((pat tc:pattern-wildcard))
    "_"))

(defgeneric check-for-var-matching-constructor (pat env)
  (:method ((pat tc:pattern-var) env)
    (declare (type tc:environment env))

    (let ((ctor (tc:lookup-constructor env (tc:pattern-var-orig-name pat) :no-error t)))
      (when ctor
        (warn 'pattern-var-matches-constructor
              :err (source:source-error
                    :type :warn
                    :location (tc:pattern-location pat)
                    :message "Pattern warning"
                    :primary-note "pattern variable matches constructor name")))))

  (:method ((pat tc:pattern-literal) env)
    (declare (ignore env)))

  (:method ((pat tc:pattern-wildcard) env)
    (declare (ignore env)))

  (:method ((pat tc:pattern-constructor) env)
    (loop :for pat :in (tc:pattern-constructor-patterns pat)
          :do (check-for-var-matching-constructor pat env))))
