;;; denote-interface.el --- Zettelkasten interfaces for Denote.el  -*- lexical-binding: t; -*-

;; Copyright (C) 2024  Kristoffer Balintona

;; Author: Kristoffer Balintona <krisbalintona@gmail.com>
;; Homepage: https://github.com/krisbalintona/denote-interface
;; Version: 1.0
;; Package-Requires: ((emacs "29.1") (org "9.3"))
;; Keywords: tools, extensions, convenience

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Useful interfaces for those who use Denote.el as a Zettelkasten, especially
;; in a similar manner as an analog Zettelkasten.

;;; Code:
(require 'tablist)
(require 'denote)
(require 's)
(require 'subr-x)
(require 'ol)

;;;; Variables
;;;;; Customizable
(defgroup denote-interface ()
  "Interfaces for denote files."
  :group 'files)

(defcustom denote-interface-starting-filter "."
  "Default regexp filter for notes."
  :type 'sexp
  :group 'denote-interface)

(defcustom denote-interface-starting-filter-presets "=="
  "The common `denote-interface-starting-filter' filters."
  :type 'regexp
  :group 'denote-interface)

(defcustom denote-interface-signature-column-width 10
  "Width for signature column."
  :type 'natnum
  :group 'denote-interface)

(defcustom denote-interface-title-column-width 85
  "Width for title column."
  :type 'natnum
  :group 'denote-interface)

(defcustom denote-interface-keyword-column-width 30
  "Width for keywords column."
  :type 'natnum
  :group 'denote-interface)

(defcustom denote-interface-unsorted-signature "000"
  "Special signature denoting \"unsorted\" note."
  :type 'string
  :group 'denote-interface)

;;;;; Internal
(defvar denote-interface--id-to-path-cache nil
  "Signature cache for `denote-interface--get-entry-path'.")

(defvar denote-interface--signature-propertize-cache nil
  "Signature cache for `denote-interface--signature-propertize'.")

(defvar denote-interface--signature-sort-cache nil
  "Signature cache for sorting via `denote-interface--signature-lessp'.")

(defvar denote-interface--signature-relations
  '("Sibling" "Child" "Top-level")
  "List of possible note relations based on signatures.
See `denote-interface--determine-new-signature' docstring for more
information.")

;;;; Functions
;;;;; Signatures
;;;;;; Parsing
(defun denote-interface--signature-elements-head-tail (group)
  "Take a signature GROUP and return a cons.
The car of this cons will be the \"front\" portion of the signature,
while the cdr of this cons will be the remaining portion of the
signature.

Right now, a \"signature portion\" is delimited by:
- The \"=\" character.
- A change from a number to letter.
- A change from a letter to number."
  (let (head tail)
    (save-match-data
      ;; HACK 2024-03-04: I hardcode "=" as an additional delimiter of signature
      ;; portions
      (if (string-match (if (s-numeric-p (substring group 0 1))
                            (rx (any alpha)) ; Numbered index head
                          (rx (any digit)))  ; Alphabet index head
                        group)
          (setq head (substring group 0 (match-beginning 0))
                tail (string-remove-prefix "=" (substring group (match-beginning 0))))
        (setq head group
              tail nil)))
    (cons head tail)))

(defun denote-interface--signature-decompose-elements-from-group (group)
  "Take a GROUP and decompose it into its elements.
Uses `denote-interface--signature-elements-head-tail'."
  (let* ((parts (denote-interface--signature-elements-head-tail group))
         (head (car parts))
         (tail (cdr parts)))
    (if tail
        (flatten-list
         (list head
               (denote-interface--signature-decompose-elements-from-group tail)))
      group)))

(defun denote-interface--signature-decompose-into-groups (sig)
  "Decompose SIG into groups."
  (when sig
    (if (string-empty-p sig)
        nil
      (string-split sig "="))))

;;;;;; Text property
(defun denote-interface--group-text-property (text sig)
  "Add the `denote-interface-sig' text property to TEXT.
Its value will be SIG. Call this function for its side effects."
  (add-text-properties 0
                       (length text)
                       (list 'denote-interface-sig (if sig
                                                       (car (denote-interface--signature-decompose-into-groups sig))
                                                     "No signature"))
                       text))

;;;;;; Determining next signature
(defun denote-interface--next-signature (sig)
  "Return the signature following SIG.
The following signature for \"a\" is \"b\", for \"9\" is \"10\", for
\"z\" is \"A\", and for \"Z\" \"aa\"."
  (let* ((groups (denote-interface--signature-decompose-into-groups sig))
         (parts (denote-interface--signature-elements-head-tail (car (last groups))))
         tail char next)
    (while (cdr parts)                  ; Get final portion of signature
      (setq parts (denote-interface--signature-elements-head-tail (cdr parts))))
    (setq tail (car parts)
          char (string-to-char tail)
          next (cond ((s-numeric-p tail) ; A number
                      (number-to-string
                       (1+ (string-to-number tail))))
                     ((and (>= char 97) (< char 122)) ; Between "a" and "z"
                      (char-to-string (1+ char)))
                     ((and (>= char 65) (< char 90)) ; Between "A" and "Z"
                      (char-to-string (1+ char)))
                     ((= 122 char) "A") ; Is "z"
                     ;; REVIEW 2024-03-03: Presently, we choose to go into
                     ;; double-letters when we go above Z
                     ((= 90 char) "aa"))) ; Is "Z"
    (concat (string-remove-suffix tail sig) next)))

(defun denote-interface--determine-new-signature (sig relation dir)
  "Return the next available signature relative to SIG.
The new signature depends on RELATION, a string in
`denote-interface--signature-relations'. If RELATION is \"child\", then
return the next signature available for a new child note. If it is
\"sibling\", then the new note will be the next available signature at
the same hierarchical level as SIG. If it is \"top-level\", then the
next available top-level signature will be returned. If RELATION is nil,
then it defaults to a value of \"child\".

If DIR is provided, check for the existence of signatures in that
directory rather than the entirety of variable `denote-directory'. DIR
can also be a file. If it is, the parent directory of that file will be
used as the directory."
  (let* ((relation (or (downcase relation) "child"))
         (dir (when dir
                (file-name-directory (file-relative-name dir denote-directory))))
         (next-sig (pcase relation
                     ("child"
                      (concat sig
                              (if (s-numeric-p (substring sig (1- (length sig))))
                                  "a" "1")))
                     ("sibling"
                      (denote-interface--next-signature sig))
                     ("top-level"
                      (let ((top-level-index 1))
                        (while (denote-directory-files
                                (rx (literal dir)
                                    (1+ anychar)
                                    "=="
                                    (literal (number-to-string top-level-index)) "=1"))
                          (setq top-level-index (1+ top-level-index)))
                        (concat (number-to-string top-level-index) "=1"))))))
    (while (member next-sig
                   (cl-loop for f in (denote-directory-files dir)
                            collect (denote-retrieve-filename-signature f)))
      (setq next-sig (denote-interface--next-signature next-sig)))
    next-sig))

;;;;;; Propertize
(defun denote-interface--signature-propertize (sig)
  "Return propertized SIG for hierarchical visibility."
  (or (and (not sig) "")
      (cdr (assoc-string sig denote-interface--signature-propertize-cache))
      (let* ((groups (denote-interface--signature-decompose-into-groups sig))
             (decomposed
              (flatten-list
               (cl-loop for group in groups
                        collect (denote-interface--signature-decompose-elements-from-group group))))
             (level (1- (length decomposed)))
             (face
              (cond
               ((string= sig denote-interface-unsorted-signature)
                'shadow)
               ((= 0 (+ 1 (% (1- level) 8)))
                'denote-faces-signature)
               (t
                (intern (format "outline-%s" (+ 1 (% (1- level) 8)))))))
             (propertized-sig
              (replace-regexp-in-string "=" (propertize "." 'face 'shadow)
                                        (propertize sig 'face face))))
        propertized-sig)))

(defun denote-interface--file-signature-propertize (path)
  "Return propertized file signature from denote PATH identifier."
  (let ((sig (denote-retrieve-filename-signature path)))
    (denote-interface--signature-propertize sig)))

;;;;;; Caching
(defun denote-interface--generate-caches ()
  "Generate caches relevant to signatures.
Speeds up `denote-interface' expensive operations. Populates the
following internal variables:
- `denote-interface--id-to-path-cache'
- `denote-interface--signature-propertize-cache'
- `denote-interface--signature-sort-cache'
- `denote-interface--top-level-minimum'
- `denote-interface--top-level-maximum'

Call this function for its side effects."
  (let* ((files (denote-directory-files))
         (sigs (cl-remove-duplicates
                (mapcar (lambda (f) (denote-retrieve-filename-signature f)) files)
                :test #'string-equal)))
    (setq denote-interface--id-to-path-cache
          (cl-loop for file in files
                   collect (cons (denote-retrieve-filename-identifier file) file))
          denote-interface--signature-sort-cache
          (sort sigs #'denote-interface--signature-lessp)
          denote-interface--signature-propertize-cache
          (cl-loop for sig in sigs
                   collect (cons sig (denote-interface--signature-propertize sig)))))
  t)

;;;;; Titles
(defun denote-interface--file-title-propertize (path)
  "Return propertized title of PATH.
If the denote file PATH has no title, return the string \"(No
Title)\".  Otherwise return PATH's title.

Determine whether a denote file has a title based on the
following rule derived from the file naming scheme:

1. If the path does not have a \"--\", it has no title."
  (let* ((titlep (string-match-p "--" path))
         (sig (denote-retrieve-filename-signature path))
         (file-type (denote-filetype-heuristics path))
         (title (denote-retrieve-front-matter-title-value path file-type))
         (face
          (cond
           ;; When SIG is the unsorted signature
           ((string= sig denote-interface-unsorted-signature)
            'denote-faces-title)
           ;; When PATH is a "indicator note" (i.e. a note strictly for
           ;; indicator subdivisions among the numbered indexes)
           ((and sig (not (cdr (denote-interface--signature-decompose-into-groups sig))))
            'denote-faces-signature)
           ;; Otherwise
           (t 'denote-faces-title))))
    (when titlep (propertize title 'face face))))

;;;;; Keywords
(defun denote-interface--file-keywords-propertize (path)
  "Return propertized keywords of PATH."
  (string-join
   (mapcar (lambda (s) (propertize s 'face 'denote-faces-keywords))
           (denote-extract-keywords-from-path path))
   (propertize ", " 'face 'shadow)))

;;;;; Entries
(defun denote-interface--get-entry-path (&optional id)
  "Get the file path of the entry at point.
ID is the ID of the `tabulated-list' entry."
  (or (cdr (assoc-string id denote-interface--id-to-path-cache))
      (let* ((id (or id (tabulated-list-get-id)))
             (path (denote-get-path-by-id id)))
        (setf (alist-get id denote-interface--id-to-path-cache) path)
        path)))

(defun denote-interface--entries-to-paths ()
  "Return list of file paths present in the `denote-interface' buffer."
  (mapcar (lambda (entry)
            (denote-interface--get-entry-path (car entry)))
          (funcall tabulated-list-entries)))

(defun denote-interface--path-to-entry (path)
  "Convert PATH to an entry in the form of `tabulated-list-entries'."
  (when path
    `(,(denote-retrieve-filename-identifier path)
      [,(denote-interface--file-signature-propertize path)
       ,(denote-interface--file-title-propertize path)
       ,(denote-interface--file-keywords-propertize path)])))

;;;;; Sorters
(defun denote-interface--signature-group-lessp (group1 group2)
  "Compare the ordering of two groups.
Returns t if GROUP1 should be sorted before GROUP2, nil otherwise."
  (when (and group1
             group2
             (or (s-contains-p "=" group1) (s-contains-p "=" group2)))
    (error "[denote-interface--signature-group-lessp] Does not accept strings with \"=\""))
  (if (and group1 group2)
      (let* ((elements1 (denote-interface--signature-elements-head-tail group1))
             (elements2 (denote-interface--signature-elements-head-tail group2))
             (head1 (car elements1))
             (head2 (car elements2))
             (tail1 (cdr elements1))
             (tail2 (cdr elements2))
             ;; HACK 2024-03-03: Right now, this treats uppercase and lowercase
             ;; as the same, as well as ignores the difference between, e.g.,
             ;; "a" and "aa"
             (index1 (string-to-number head1 16))
             (index2 (string-to-number head2 16)))
        (cond
         ;; Group1 is earlier in order than group2
         ((< index1 index2) t)
         ;; Group2 is later than group2
         ((> index1 index2) nil)
         ;; Group1 has no tail while group2 has a tail, so it's later than
         ;; group2
         ((and (not tail1) tail2) t)
         ;; Group1 has a tail while group2 has no tail, so it's earlier than
         ;; group2
         ((and tail1 (not tail2)) nil)
         ;; Neither group2 nor group2 have a tail, and their indexes must be
         ;; equal, so they must have identical signatures. So do something with
         ;; it now. (Returning nil seems to put the oldest earlier, so we do
         ;; that.)
         ((and (not tail1) (not tail2)) nil)
         ;; Their indices are equal, and they still have a tail, so process
         ;; those tails next
         ((= index1 index2)
          (denote-interface--signature-group-lessp tail1 tail2))))
    ;; When one or both of group1 and group2 are not supplied
    (cond
     ;; If neither are supplied, then use `string-collate-lessp'
     ((not (or group1 group2))
      (string-collate-lessp group1 group2))
     ;; If group1 is present but not group2, then return true so that group1 can
     ;; be earlier in the list
     ((and group1 (not group2))
      t)
     ;; If group2 is present but not group1, then return nil to put group2
     ;; earlier
     ((and (not group1) group2)
      nil))))

(defun denote-interface--signature-lessp (sig1 sig2)
  "Compare two strings based on my signature sorting rules.
Returns t if SIG1 should be sorted before SIG2, nil otherwise.

This function splits SIG1 and SIG2 into indexical groups with
`denote-interface--signature-decompose-into-groups' and compares the first
group of each. If SIG1 is not definitively before SIG2, then recursively
call this function on the remaining portion of the signature.

For faster computation after first invocation of `denote-interface',
leverages `denote-interface--signature-sort-cache' as a cache."
  (if (and (string-empty-p sig1) (string-empty-p sig2))
      (let ((cache denote-interface--signature-sort-cache))
        (and (member sig1 cache)
             (member sig2 cache)
             (< (cl-position sig1 cache :test #'equal)
                (cl-position sig2 cache :test #'equal))))
    (let ((groups1 (denote-interface--signature-decompose-into-groups sig1))
          (groups2 (denote-interface--signature-decompose-into-groups sig2)))
      (cond
       ;; Return t when: if sig1's groups have so far been after sig2's, but
       ;; sig2 has more groups while sig1 does not, then this means sig2
       ;; ultimately goes after sig1
       ((and (not sig1) sig2) t)
       ;; Return nil when: if all of sig1's groups go after sig2's groups, then
       ;; sig2 is after sig1
       ((not (and sig1 sig2)) nil)
       ;; When the car of groups1 and groups2 are the same, then recursively
       ;; call this function on the remaining portion of the signature
       ((string= (car groups1) (car groups2))
        (let ((remaining-groups1 (string-join (cdr groups1) "="))
              (remaining-groups2 (string-join (cdr groups2) "=")))
          (denote-interface--signature-lessp
           (unless (string-empty-p remaining-groups1) remaining-groups1)
           (unless (string-empty-p remaining-groups2) remaining-groups2))))
       (t
        (denote-interface--signature-group-lessp (pop groups1) (pop groups2)))))))

(defun denote-interface--signature-sorter (a b)
  "Tabulated-list sorter for entries A and B.
Note that this function needs to be performant, otherwise
`denote-interface' loading time suffers greatly."
  (let* ((sig1 (aref (cadr a) 0))
         (sig2 (aref (cadr b) 0)))
    ;; FIXME 2024-03-04: I have to replace "."s with "=" because in
    ;; `denote-interface--path-to-entry' I do the reverse. This is quite
    ;; fragile, so try to find a more robust alternative
    (setq sig1 (replace-regexp-in-string "\\." "=" sig1)
          sig2 (replace-regexp-in-string "\\." "=" sig2))
    (denote-interface--signature-lessp sig1 sig2)))

;;;; Commands
;;;;; Filtering
;;;###autoload
(defun denote-interface-edit-filter ()
  "Edit the currently existing filter."
  (interactive)
  (setq denote-interface-starting-filter
        (read-from-minibuffer "Filter regex: " denote-interface-starting-filter))
  (revert-buffer))

;;;###autoload
(defun denote-interface-edit-filter-presets ()
  "Edit the currently existing filter."
  (interactive)
  (setq denote-interface-starting-filter
        (completing-read "Filter preset: "
                         (remove denote-interface-starting-filter denote-interface-starting-filter-presets)))
  (revert-buffer))

;;;;; Viewing
;;;###autoload
(defun denote-interface-goto-note ()
  "Jump to the note corresponding to the entry at point."
  (interactive)
  (find-file (denote-interface--get-entry-path)))

;;;###autoload
(defun denote-interface-goto-note-other-window ()
  "Open in another window the note corresponding to the entry at point."
  (interactive)
  (find-file-other-window (denote-interface--get-entry-path)))

;;;###autoload
(defun denote-interface-display-note ()
  "Just display the current note in another window."
  (interactive)
  (display-buffer (find-file-noselect (denote-interface--get-entry-path)) t))

;;;;; Signatures
;;;###autoload
(defun denote-interface-set-signature (path new-sig)
  "Set the note at point's (in `denote-interface' buffer) signature.
Can be called interactively from a denote note or a `denote-interface'
entry. If called non-interactively, set the signature of PATH to
NEW-SIG."
  (interactive (list (cond ((derived-mode-p 'denote-interface-mode)
                            (denote-interface--get-entry-path))
                           ((denote-file-is-note-p (buffer-file-name))
                            (buffer-file-name))
                           (t
                            (user-error "Must use in `denote-interface' or a Denote note!")))
                     nil))
  (let* ((path (or path (denote-interface--get-entry-path)))
         (file-type (denote-filetype-heuristics path))
         (title (denote-retrieve-title-value path file-type))
         (initial-sig (denote-retrieve-filename-signature path))
         (new-sig (or new-sig
                      (denote-signature-prompt
                       (unless (string= initial-sig denote-interface-unsorted-signature)
                         initial-sig)
                       "Choose new signature")))
         (keywords
          (denote-retrieve-front-matter-keywords-value path file-type))
         (denote-rename-no-confirm t))  ; Want it automatic
    (denote-rename-file path title keywords new-sig)))

;;;###autoload
(defun denote-interface-set-signature-minibuffer (files)
  "Set the note at point's signature by selecting another note.
Select another note and choose whether to be its the sibling or child.

Also accepts FILES, which are the list of file paths which are
considered.

If nil or called interactively, then defaults `denote-directory-files'
constrained to notes with signatures (i.e. \"==\") and are in the
current subdirectory (this is my bespoke desired behavior), as well as
the :omit-current non-nil. Otherwise,when called interactively in
`denote-interface', it will be the value of
`denote-interface--entries-to-paths'."
  (interactive (list (if (eq major-mode 'denote-interface-mode)
                         (denote-interface--entries-to-paths)
                       (denote-directory-files
                        (rx (literal (car (last (butlast (file-name-split (buffer-file-name)) 1))))
                            "/" (* alnum) "==")
                        :omit-current))))
  (let* ((file-at-point (cond ((derived-mode-p 'denote-interface-mode)
                               (denote-interface--get-entry-path))
                              ((denote-file-is-note-p (buffer-file-name))
                               (buffer-file-name))
                              (t
                               (user-error "Must use in `denote-interface' or a Denote note!"))))
         (files (remove file-at-point
                        (or files (denote-directory-files
                                   (rx (literal (car (last (butlast (file-name-split (buffer-file-name)) 1))))
                                       "/" (* alnum) "==")
                                   :omit-current))))
         (files
          (cl-loop for file in files collect
                   (let ((sig (denote-retrieve-filename-signature file)))
                     (denote-interface--group-text-property file sig)
                     file)))
         (largest-sig-length
          (cl-loop for file in files
                   maximize (length (denote-retrieve-filename-signature file))))
         (display-sort-function
          (lambda (completions)
            (cl-sort completions
                     'denote-interface--signature-lessp
                     :key (lambda (c) (denote-retrieve-filename-signature c)))))
         (group-function
          (lambda (title transform)
            (if transform
                title
              (get-text-property 0 'denote-interface-sig title))))
         (affixation-function
          (lambda (files)
            (cl-loop for file in files collect
                     (let* ((propertized-title (denote-interface--file-title-propertize file))
                            (sig (denote-retrieve-filename-signature file))
                            (propertized-sig (denote-interface--file-signature-propertize file)))
                       (denote-interface--group-text-property propertized-title sig)
                       (list propertized-title
                             (string-pad propertized-sig (+ largest-sig-length 3))
                             nil)))))
         (selection
          (completing-read "Choose a note: "
                           (lambda (str pred action)
                             (if (eq action 'metadata)
                                 `(metadata
                                   (display-sort-function . ,display-sort-function)
                                   (group-function . ,group-function)
                                   (affixation-function . ,affixation-function))
                               (complete-with-action action files str pred)))
                           nil t))
         (note-relation
          (downcase (completing-read "Choose relation: " denote-interface--signature-relations)))
         (new-sig (denote-interface--determine-new-signature
                   (denote-retrieve-filename-signature selection)
                   note-relation
                   selection))
         (denote-rename-no-confirm t))
    (denote-interface-set-signature file-at-point new-sig)))

;;;###autoload
(defun denote-interface-set-signature-list (files)
  "Set the note at point's signature by selecting another note.
Like `denote-interface-set-signature-minibuffer' but uses
`denote-interface-selection-mode' instead of minibuffer.

FILES are the list of files shown, defaulting to all denote files. When
\"RET\" or \"q\" is called on a note, the new signature of the file to
be modified will be set relative to that note. See
`denote-interface--determine-new-signature' for more details."
  (interactive (list (if (eq major-mode 'denote-interface-mode)
                         (progn
                           (revert-buffer) ; Ensure entries align with changes to files
                           (cl-remove
                            ;; Ensure the note whose signature is being modified
                            ;; is not in the resultant list of files
                            (denote-interface--get-entry-path)
                            (denote-interface--entries-to-paths)
                            :test #'string-equal))
                       (denote-directory-files
                        (rx (literal (concat (car (last (butlast (file-name-split (buffer-file-name)) 1)))
                                             "/"))
                            (* alnum) "==")
                        :omit-current))))
  (let* ((file-at-point (cond ((derived-mode-p 'denote-interface-mode)
                               (denote-interface--get-entry-path))
                              ((denote-file-is-note-p (buffer-file-name))
                               (buffer-file-name))
                              (t
                               (user-error "Must use in `denote-interface' or a Denote note!"))))
         (files (remove file-at-point
                        (or files (denote-directory-files
                                   (rx (literal (car (last (butlast (file-name-split (buffer-file-name)) 1))))
                                       "/" (* alnum) "==")
                                   :omit-current))))
         (file-type (denote-filetype-heuristics file-at-point))
         (buf-name (format "*Modify the signature of %s %s*"
                           (denote-retrieve-filename-signature file-at-point)
                           (denote-retrieve-front-matter-title-value file-at-point file-type)))
         (select-func
          `(lambda ()
             "Change desired note's signature relate to the chosen note."
             (interactive)
             (let* ((selection (denote-interface--get-entry-path))
                    (note-relation
                     (downcase (completing-read "Choose relation: "
                                                denote-interface--signature-relations)))
                    (new-sig (denote-interface--determine-new-signature
                              (denote-retrieve-filename-signature selection)
                              note-relation
                              selection))
                    (denote-rename-no-confirm t)) ; Want it without confirmation
               (denote-interface-set-signature ,file-at-point new-sig)
               (kill-buffer ,buf-name))))
         (confirm-quit-func
          `(lambda ()
             "Kill buffer with confirmation"
             (interactive)
             (when (y-or-n-p (format "Leave before modifying signature of %s?"
                                     ,(denote-retrieve-front-matter-title-value file-at-point file-type)))
               (kill-buffer ,buf-name))))
         (keymap (make-sparse-keymap)))
    (denote-interface-list buf-name)
    (with-current-buffer buf-name
      (setq tabulated-list-entries
            (lambda () (mapcar #'denote-interface--path-to-entry files)))
      (revert-buffer)
      (set-keymap-parent keymap denote-interface-mode-map)
      (define-key keymap (kbd "RET") select-func)
      (define-key keymap (kbd "q") confirm-quit-func)
      (use-local-map keymap))))

;;;;; Navigation
;;;###autoload
(defun denote-interface-filter-top-level-previous (N)
  "Filter the buffer to the next index top-level notes.
Go backward N top-levels.

Uses `tablist' filters."
  (interactive (list (or (and (numberp current-prefix-arg)
                              (- current-prefix-arg))
                         -1)))
  (denote-interface-filter-top-level-next N))

;;;###autoload
(defun denote-interface-filter-top-level-next (N)
  "Filter the buffer to the next index top-level notes.
Go forward N top-levels.

Uses `tablist' filters."
  (interactive (list (or (and (numberp current-prefix-arg)
                              current-prefix-arg)
                         1)))
  (let* ((path (denote-interface--get-entry-path))
         (sig (denote-retrieve-filename-signature path))
         (sig-top-level
          (string-to-number (car (denote-interface--signature-decompose-into-groups sig))))
         (min-top-level (cl-loop for f in (denote-directory-files denote-interface-starting-filter)
                                 minimize (string-to-number
                                           (or (car
                                                (denote-interface--signature-decompose-into-groups
                                                 (denote-retrieve-filename-signature f)))
                                               ""))))
         (max-top-level (cl-loop for f in (denote-directory-files denote-interface-starting-filter)
                                 maximize (string-to-number
                                           (or (car
                                                (denote-interface--signature-decompose-into-groups
                                                 (denote-retrieve-filename-signature f)))
                                               ""))))
         (next-top-level (+ N sig-top-level))
         (next-top-level
          (cond
           ((and (<= min-top-level next-top-level) (<= next-top-level max-top-level))
            next-top-level)
           ((< next-top-level min-top-level)
            (+ max-top-level sig-top-level))
           ((< max-top-level next-top-level)
            (- sig-top-level max-top-level))))
         (regexp
          (if (= next-top-level (string-to-number denote-interface-unsorted-signature))
              (rx bol (literal denote-interface-unsorted-signature))
            (rx bol (literal (number-to-string next-top-level)) (or (literal ".") eol)))))
    ;; OPTIMIZE 2024-03-17: Right now this assumes that the head of the filters
    ;; is a previous filter made by this command.
    (tablist-pop-filter 1)
    (tablist-push-regexp-filter "Signature" regexp)))

;;;;; Storing
;;;###autoload
(defun denote-interface-store-link ()
  "Call `org-store-link' on the entry at point if an org file."
  (interactive)
  (when-let* ((file (denote-interface--get-entry-path))
              (file-id (denote-retrieve-filename-identifier file))
              (description (denote--link-get-description file))
              (orgp (string= "org" (file-name-extension file))))
    ;; Populate `org-store-link-plist'. Inspired by `denote-link-ol-store'
    (org-link-store-props
     :type "denote"
     :description description
     :link (concat "denote:" file-id))
    ;; Then add to `org-stored-links'
    (push (list (plist-get org-store-link-plist :link)
                (plist-get org-store-link-plist :description))
          org-stored-links)
    (message "Stored %s!" (file-relative-name file denote-directory))))

;;;; Major-modes and keymaps
(defvar denote-interface-mode-map
  (let ((km (make-sparse-keymap)))
    (define-key km (kbd "/d") #'denote-interface-edit-filter-presets)
    (define-key km (kbd "/D") #'denote-interface-edit-filter)
    (define-key km (kbd "RET") #'denote-interface-goto-note)
    (define-key km (kbd "o") #'denote-interface-goto-note-other-window)
    (define-key km (kbd "C-o") #'denote-interface-display-note)
    (define-key km (kbd "r") #'denote-interface-set-signature-list)
    (define-key km (kbd "R") #'denote-interface-set-signature-minibuffer)
    (define-key km (kbd "w") #'denote-interface-store-link)
    (define-key km (kbd "M-p") #'denote-interface-filter-top-level-previous)
    (define-key km (kbd "M-n") #'denote-interface-filter-top-level-next)
    km)
  "Mode map for `denote-interface-mode'.")
(set-keymap-parent denote-interface-mode-map tablist-mode-map)

(define-derived-mode denote-interface-mode tablist-mode "Denote Interface"
  "Major mode for interfacing with Denote files."
  :interactive nil
  :group 'denote-interface
  :after-hook (set (make-local-variable 'mode-line-misc-info)
                   (append
                    (list
                     (list 'denote-interface-starting-filter
                           '(:eval (format " [%s]" denote-interface-starting-filter))))))
  (unless (and denote-interface--id-to-path-cache
               denote-interface--signature-sort-cache
               denote-interface--signature-propertize-cache
               denote-interface--top-level-minimum
               denote-interface--top-level-maximum)
    (denote-interface--generate-caches))
  (setq tabulated-list-format
        `[("Signature" ,denote-interface-signature-column-width denote-interface--signature-sorter)
          ("Title" ,denote-interface-title-column-width t)
          ("Keywords" ,denote-interface-title-column-width nil)]
        tabulated-list-entries
        (lambda () (mapcar #'denote-interface--path-to-entry
                      (denote-directory-files denote-interface-starting-filter)))
        tabulated-list-sort-key '("Signature" . nil))
  (use-local-map denote-interface-mode-map)
  (tabulated-list-init-header)
  (tabulated-list-print))

(defun denote-interface-list (name)
  "Display list of Denote files in variable `denote-directory'.
If NAME is supplied, that will be the name of the buffer."
  (interactive (list nil))
  (let ((buf-name (or name
                      (format "*Denote notes in %s*"
                              (abbreviate-file-name (buffer-local-value 'denote-directory (current-buffer)))))))
    ;; TODO 2024-03-28: Haven't figured out how to adhere to the current
    ;; denote-silo convention of setting `denote-directory' in .dir-locals
    (unless (get-buffer buf-name)
      (with-current-buffer (get-buffer-create buf-name)
        (setq buffer-file-coding-system 'utf-8)
        (denote-interface-mode)))
    (display-buffer buf-name)))

;;; [End]
(provide 'denote-interface)
;;; denote-interface.el ends here
