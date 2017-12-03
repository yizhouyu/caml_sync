(* [diff] represents an ocaml diff object between contents *)
type diff

type file_diff = {
  file_name: string;
  is_deleted: bool;
  content_diff: diff;
}

type version_diff = {
  prev_version: int;
  cur_version: int;
  edited_files: file_diff list
}

exception File_existed of string
exception File_not_found of string

(* [calc_diff base_content new_content] returns the difference between
 * [base_content] and [new_content] *)
val calc_diff : string list -> string list -> diff

(* [apply_diff base_content diff_content] returns the result
 * after applying the changes in [diff_content] to [base_content] *)
val apply_diff : string list -> diff -> string list

(* [build_diff_json diff_obj] returns the diff json representing
 * the ocaml diff object [diff_obj] *)
val build_diff_json : diff -> [> Ezjsonm.t ]

(* [parse_diff_json diff_json] returns an ocaml diff object
 * represented by [diff_json] *)
val parse_diff_json : Ezjsonm.t -> diff

(* [build_version_diff_json v_diff] returns a json representing
 * the ocaml version_diff object [version_diff] *)
val build_version_diff_json : version_diff -> [> Ezjsonm.t ]

(* [parse_version_diff_json v_json] returns an ocaml version_diff object
 * represented by [v_json] *)
val parse_version_diff_json : Ezjsonm.t -> version_diff

(* [write_json w_json filename] writes the json to an output file
 * specified by [filename] *)
val write_json : [> Ezjsonm.t ] -> string -> unit

(* [write_file filename content] creates a new file named [filename].
 * [filename] may include any sub-directory.
 * [content] is a list of lines representing the content
 * to be written to the new file.
 * raises: [File_existed "Cannot create file."] if there already exists
* a file with the same name as [filename] *)
val write_file : string -> string list -> unit

(* [delete_file filename] deletes a file named [filename].
 * raises: [File_not_found "Cannot remove file."] if [filename] cannot be found *)
val delete_file : string -> unit
