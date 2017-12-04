open Core

type config = {
  client_id: string;
  url: string;
  token: string;
  version: int;
}

(* [load_config () ] loads the config file of client *)
val load_config : unit -> config

(* [update_config config] updates the [.config] file with [config] *)
val update_config : config -> unit

(* [get_latest_version config] sends a query to the server and returns
 * the server's current version number *)
val get_latest_version : config -> int option

(* [get_update_diff config]
 * retrieves the current version of the working directory from [config],
 * sends a post request to the server to retrieve the difference between
 * the local version and the server's latest version, and returns the difference
 *)
val get_update_diff : config -> version_diff

(* [post_local_diff config version_diff] sends the difference between the local version
 * and the server version to the server via json
 *)
val post_local_diff : config -> version_diff -> int

(* [compare_file filename] returns the all the updates that the user has made
 * since the latest sync *)
 val compare_file : string -> file_diff

(* [compare_working_backup () ] returns the list of file_diff that have been modified
 * after the last sync with the server
 *)
val compare_working_backup : unit -> file_diff list

(* [check_both_modified_files modified_file_diffs version_diff]
 * returns a list of filenames that indicates files that are inconsistent
 * in the following three versions: the local working version,
 * the remote server version, and the backup version in the hidden folder *)
val check_both_modified_files : file_diff list -> version_diff -> string list

(* [rename_both_modified both_modified] renames local files in [both_modified]
 * by appending "_local" to their filenames, because those files
 * have merge conflicts *)
val rename_both_modified : string list -> unit

(* [generate_client_version_diff server_diff] is the [Some client_diff] where [client_diff] is the new update this client has made. If this client does not make any update, the result of this function is [None]. *)
val generate_client_version_diff : version_diff -> version_diff option

(* [compare_working_backup both_modified] compares all the files in current
 * working directory to the backup version. The backup version is the previous
 * local version in the hidden directory ".caml_sync/".
 *)
(* val compare_working_backup : string list -> file_diff list *)

(* [backup_working_files _] makes a copy for all the files in current working
 * directory and back them up in ".caml_sync/".
 *)
val backup_working_files : unit -> unit

(* [init url token] creates a hidden ".config" file and stores [url] and [token]
 * in ".config". It also creates a folder ".caml_sync/" in the current directory.
 * Users can change this [url] and [token] manually in ".config". *)
val init : string -> string -> unit Lwt.t

(* Performs all the sync work *)
val sync : unit Lwt.t
