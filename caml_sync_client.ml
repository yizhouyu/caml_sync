open Core
open Lwt
open Cohttp
open Cohttp_lwt_unix
open Ezjsonm

module StrSet = Set.Make (String)

exception Timeout
exception Unauthorized
exception Bad_request of string
exception ServerError of string
exception Not_Initialized

(* week, month list used to format date. *)
let week = ["Sun";"Mon";"Tue";"Wed";"Thu";"Fri";"Sat"]
let month = ["Jan";"Feb";"Mar";"Apr";"May";"Jun";
             "Jul";"Aug";"Sep";"Oct";"Nov";"Dec"]

(* [hidden_dir] is the directory storing the backup file. *)
let hidden_dir = ".caml_sync"

(* [history_dir_prefix] is the prefix of history backup folder name. *)
let history_dir_prefix = "./camlsync_history_version_"

(* [valid_extensions] is a list of extensions that camlsync accepts.
 * All files without these extensions will be ignored. *)
let valid_extensions = [".ml"; ".mli"; ".txt"; ".sh"; ".java"; ".c"; ".h";
                        ".md"; ".cpp"; ".py"; ".jl"; ".m"; ".csv"; ".json"]

(* [unwanted_strs] is a list of files and folders that should be ignored
 *  by camlsync. *)
let unwanted_strs =
  ["." ^ Filename.dir_sep ^ hidden_dir ^ Filename.dir_sep;
   "." ^ Filename.dir_sep ^ ".config";
   history_dir_prefix]

(* [usage] is the usage message. *)
let usage = "usage: camlsync [<init [url token]> | <clean> | <checkout> |\n\
             \t\t<status> | <history num | list | clean> | <conflict [clean]>]"

type config = {
  client_id: string;
  url: string;
  token: string;
  version: int;
}

(* [timeout ()] timeout after 5 seconds. *)
let timeout =
  fun () -> bind (Lwt_unix.sleep 5.) (fun _ -> raise Timeout)

let load_config () =
  try
    let dict = get_dict (from_channel (open_in ".config")) in
    try
      {
        client_id = get_string (List.assoc "client_id" dict);
        url = get_string (List.assoc "url" dict);
        token = get_string (List.assoc "token" dict);
        version = get_int (List.assoc "version" dict);
      }
    with
    | Not_found -> raise Not_Initialized
  with
  | Sys_error e -> raise Not_Initialized

let update_config config =
  try
    let json =
      dict [
        "client_id", (string config.client_id);
        "url", (string config.url);
        "token", (string config.token);
        "version", (int config.version);
      ] in
    let out = open_out ".config"in
    to_channel out json;
    flush out
  with
  | _ ->
    raise Not_Initialized

(* [get_all_filenames dir] returns a set of all the filenames
 * in directory [dir] or its subdirectories that are of approved suffixes *)
let get_all_filenames dir =
  let d_handle =
    try Unix.opendir dir  with | _ -> raise Not_found
  in search_dir d_handle StrSet.add StrSet.empty [] dir valid_extensions

let post_local_diff config version_diff =
  let open Uri in
  let uri = Uri.of_string  ("//"^config.url) in
  let uri = with_path uri "diff" in
  let uri = with_scheme uri (Some "http") in
  let uri = Uri.add_query_param' uri ("token", config.token) in
  let body = version_diff |> Core.build_version_diff_json
             |> Ezjsonm.to_string |> Cohttp_lwt__Body.of_string in
  let request = Client.post ~body:(body) uri
    >>= fun (resp, body) ->
    let code = resp |> Response.status |> Code.code_of_status in
    if code = 401 then raise Unauthorized
    else if code = 400
    then raise (Bad_request ("Bad_request when " ^
                             "posting local diff to the server."))
    else try (
      body |> Cohttp_lwt.Body.to_string >|= fun body ->
      match body |> from_string with
      | `O lst ->
        begin match List.assoc_opt "version" lst with
          | Some v ->
            get_int v
          | None ->
            raise (ServerError "Unexpected response: not field version")
        end
      | _ -> raise (ServerError "Unexpected response")
    ) with _ -> raise (ServerError "Unexpected response body format")
  in Lwt_main.run (Lwt.pick [request; timeout ()])

(* [compare_file filename] returns all the updates that the user has made
 * on the file represented by [filename] since the latest sync *)
let compare_file filename =
  let cur_file_content = read_file filename in
  let old_file_content =
    try read_file (hidden_dir ^ Filename.dir_sep ^ filename)
    with | File_not_found _ -> [] (* this file is newly created *)
  in {
    file_name = filename;
    is_deleted = false;
    content_diff = Diff_Impl.calc_diff old_file_content cur_file_content
  }

(* [replace_prefix str prefix_old prefix_new] replaces the prefix [prefix_old]
 * of [str] with [prefix_new]
 * requires: [prefix_old] is a prefix of [str] *)
let replace_prefix str prefix_old prefix_new =
  let open String in
  if length str < length prefix_old
  then failwith "prefix to be replaced does not exist in current string"
  else let suffix =
         sub str (length prefix_old) (length str - length prefix_old) in
    prefix_new ^ suffix

(* [has_prefix_in_lst str_to_check lst_prefices] checks whether [str_to_check]
 * has a prefix in [lst_prefices] *)
let has_prefix_in_lst str_to_check lst_prefices =
  List.fold_left
    (fun acc elem ->
       try
         let sub_str = String.sub str_to_check 0 (String.length elem) in
         if sub_str = elem then true else acc
       with | Invalid_argument _ -> acc
    ) false lst_prefices

(* [contains_local filename] checks whether [filename] contains "_local"
 * right before its extension *)
let contains_local filename =
  let no_extension = Filename.chop_extension filename in
  let open String in
  let from_i = length no_extension - length "_local" in
  try
    let match_str = sub filename from_i (length "_local")    in
    match_str = "_local"
  with | _ -> false

(* [check_invalid_filename ()] returns true if the local directory contains
 * any file whose filename (excluding file extension) ends with "_local" *)
let check_invalid_filename () =
  let filenames_cur = get_all_filenames "." in
  StrSet.fold
    (fun elem acc ->
       if has_prefix_in_lst elem unwanted_strs then acc (* skip this file *)
       else if contains_local elem
       then StrSet.add elem acc
       else acc)
    filenames_cur StrSet.empty |> StrSet.elements

(* [compare_working_backup () ] returns a list of file_diff's that
 * have been modified after the last sync with the server.
 * The previous local version is stored in the hidden directory ".caml_sync/".
*)
let compare_working_backup () =
  let filenames_last_sync =
    try get_all_filenames hidden_dir
    with _ -> raise Not_Initialized
  in
  let filenames_cur =
    get_all_filenames "." |> StrSet.filter
      (fun elem -> not(has_prefix_in_lst elem unwanted_strs)) in
  let working_files_diff_lst =
    (* all files in working directory *)
    StrSet.fold
      (fun f_name acc -> (compare_file f_name)::acc) filenames_cur []
    |> List.filter (fun {content_diff} -> content_diff <> Diff_Impl.empty)
  in
  (* all files in sync directory but not in working direcoty.
   * These files have been removed after the last update *)
  let trans_filenames_last_sync =
    (* map every string in filenames_last_sync to a new string with "."
     * as prefix rather than hidden_dir *)
    StrSet.map
      (fun str -> replace_prefix str hidden_dir ".") filenames_last_sync in
  let deleted_files =
    StrSet.diff trans_filenames_last_sync filenames_cur in
  let added_files =
    StrSet.diff filenames_cur trans_filenames_last_sync in
  working_files_diff_lst 
  |> StrSet.fold
    (fun f_name acc ->
       {
         file_name = f_name;
         is_deleted = true;
         content_diff = Diff_Impl.calc_diff [] []
       }::acc) deleted_files
  |> StrSet.fold (fun f_name acc ->
      {
        file_name = f_name;
        is_deleted = false;
        content_diff = Diff_Impl.calc_diff [] []
      }::acc) added_files

(* [check_both_modified_files modified_file_diffs version_diff]
 * returns a list of [(filename, is_deleted)] that indicates files that are
 * inconsistent in the following three versions: the local working version,
 * the remote server version, and the backup version in the hidden folder. If
 * [is_deleted] is true, it means that that file is deleted in the local working
 * version compared with the backup version. *)
let check_both_modified_files modified_file_diffs version_diff =
  let server_diff_files = version_diff.edited_files in
  let check_modified clt_file =
    if List.exists (fun f -> f.file_name = clt_file.file_name) server_diff_files
    then Some (clt_file.file_name, clt_file.is_deleted)
    else None in
  let modified_files_option = List.map check_modified modified_file_diffs in
  List.fold_left (fun acc ele ->
      match ele with
      | Some e -> e :: acc
      | None -> acc
    ) [] modified_files_option

(* [rename_both_modified both_modified_list] delete or renames local files in
 * [both_modified_list] by appending "_local" to their filenames,
 * because those files have merge conflicts. [both_modified_list] is a list of
 * [(filename, is_deleted)]. The [is_deleted] indicates whether we should delete
 * or rename the file. If [is_deleted] is true, we should delete the file. *)
let rename_both_modified both_modified_lst =
  List.iter
    (fun (elem, to_delete) ->
       if to_delete then delete_file elem
       else let extension = Filename.extension elem in
         let old_f_name = Filename.chop_extension elem in
         Sys.rename elem (old_f_name ^ "_local" ^ extension)) both_modified_lst

(* copy a file at [from_name] to [to_name], creating additional directories
 * if [to_name] indicates writing a file deeper down than the current directory
*)
let copy_file from_name to_name =
  write_file to_name (read_file from_name)

(* [copy_files from_names to_names] copy all files in [from_names] to
 * [to_names]. If some files in [from_names] do not exist, this function will
 * ignore them. *)
let copy_files from_names to_names =
  List.iter2 (fun f t ->
      if Sys.file_exists f then
        copy_file f t
    ) from_names to_names

(* [backup_working_files ()] copies all the files in current working
 * directory to ".caml_sync/", except those files in that contain "_local" at the
 * end of their filename
*)
let backup_working_files () =
  let filenames_cur =
    get_all_filenames "." |> StrSet.filter
      (fun elem -> not(has_prefix_in_lst elem unwanted_strs)) in
  StrSet.iter (fun f ->
      let to_name = replace_prefix f "." hidden_dir in
      copy_file f to_name) filenames_cur

(* [remove_dir_and_files folder_name] removes the folder [folder_name] and its
 * content. It is equal to "rm -rf folder_name" in Unix. If [folder_name] is not
 * found, do nothing here. *)
let remove_dir_and_files folder_name =
  try
    get_all_filenames folder_name |> StrSet.iter delete_file;
    if Sys.file_exists folder_name then
      Unix.rmdir folder_name
  with
  | Not_found -> ()

(* [apply_v_diff_to_dir v_diff dir_prefix] applies the version_diff [v_diff] to
 * the directory indicated by dir_prefix
 * requires: the string for [dir_prefix] does not end with '/'
*)
let apply_v_diff_to_dir v_diff dir_prefix =
  List.iter (fun {file_name; is_deleted; content_diff} ->
      let f_name = replace_prefix file_name "." dir_prefix in
      if is_deleted
      then delete_file f_name
      else
        let content =
          if Sys.file_exists f_name
          then
            let content' = read_file f_name in
            delete_file f_name;
            content'
          else [] in
        Diff_Impl.apply_diff content content_diff |> write_file f_name
    ) v_diff.edited_files

(* [generate_client_version_diff server_diff] returns
 * [(both_modified_lst, local_diff_files)].
 *)
let generate_client_version_diff server_diff =
  (* 0. create local_diff with compare_working_backup. *)
  let local_files_diff = compare_working_backup () in
  (* 1. Get the list of files modified on both sides . *)
  let both_modified_lst =
    check_both_modified_files local_files_diff server_diff in
  (* 2. rename files in both_modified_lst. *)
  rename_both_modified both_modified_lst;
  (* 3. copy files in both_modified_lst from hidden to local
   * directory. *)
  let to_file_names =
    both_modified_lst |> List.map (fun (filename, is_deleted) -> filename) in
  let from_file_names =
    to_file_names |> List.map
      (fun filename -> replace_prefix filename "." hidden_dir) in
  copy_files from_file_names to_file_names;
  (* 4. remove everything in hidden directory. *)
  remove_dir_and_files hidden_dir;
  (* 5. apply server_diff to local directory. *)
  apply_v_diff_to_dir server_diff ".";
  (* 6. call backup_working_files to copy everything from local
   * directory to hidden directory. *)
  backup_working_files ();
  (* if there is not a hidden dir, create one *)
  if not (Sys.file_exists hidden_dir) then
    Unix.mkdir hidden_dir 0o770
  else ();
  (* 7. remove files in both_modified_list from local_diff
   * and return the resulting version_diff *)
  let return_files_diff = List.filter (fun {file_name} ->
      List.exists
        (fun (ele, _) -> ele = file_name)
        both_modified_lst |> not
    ) local_files_diff in
  (both_modified_lst, return_files_diff)

let get_update_diff config =
  let open Uri in
  let uri = Uri.of_string  ("//"^config.url) in
  let uri = with_path uri "diff" in
  let uri = with_scheme uri (Some "http") in
  let uri = Uri.add_query_param' uri ("token", config.token) in
  let uri = Uri.add_query_param' uri ("from", string_of_int config.version) in
  let request = Client.get uri
    >>= fun (resp, body) ->
    let code = resp |> Response.status |> Code.code_of_status in
    if code = 401 then raise Unauthorized
    else if code = 400
    then raise (Bad_request "Bad_request when getting diff from the server.")
    else
      try (
        body |> Cohttp_lwt.Body.to_string >|= fun body ->
        let diff = body |> from_string |> parse_version_diff_json in
        update_config {config with version=diff.cur_version};
        begin
          if config.version = diff.cur_version
          then
            print_endline "Already the latest version."
          else
            print_endline ("Fetch from the server and update to version "
                           ^ (string_of_int diff.cur_version) ^ ".")
        end;
        generate_client_version_diff diff
      )
      with
      | _ ->
        raise (ServerError "During getting update diff")
  in Lwt_main.run (Lwt.pick [request; timeout ()])

let history_list config =
  let open Uri in
  let uri = Uri.of_string  ("//"^config.url) in
  let uri = with_path uri "history" in
  let uri = with_scheme uri (Some "http") in
  let uri = Uri.add_query_param' uri ("token", config.token) in
  let request = Client.get uri
    >>= fun (resp, body) ->
    let code = resp |> Response.status |> Code.code_of_status in
    if code = 401 then raise Unauthorized
    else
      try (
        body |> Cohttp_lwt.Body.to_string >|= fun body ->
        body |> from_string |> parse_history_log_json
      ) with |_ -> raise (ServerError "During getting history list")
  in Lwt_main.run (Lwt.pick [request; timeout ()])

let time_travel config v =
  let new_dir = history_dir_prefix ^ (string_of_int v) in
  if Sys.file_exists new_dir then begin
    remove_dir_and_files new_dir;
    print_endline (new_dir ^ " is refreshed.");
  end;
  let open Uri in
  let uri = Uri.of_string  ("//"^config.url) in
  let uri = with_path uri "diff" in
  let uri = with_scheme uri (Some "http") in
  let uri = Uri.add_query_param' uri ("token", config.token) in
  let uri = Uri.add_query_param' uri ("to", string_of_int v) in
  let request = Client.get uri
    >>= fun (resp, body) ->
    let code = resp |> Response.status |> Code.code_of_status in
    if code = 401 then raise Unauthorized
    else if code = 400
    then raise (Bad_request ("Bad_request when "
                             ^ "getting history version from the server."))
    else try (
      body |> Cohttp_lwt.Body.to_string >|= fun body ->
      let version_diff = body |> from_string |> parse_version_diff_json in
      apply_v_diff_to_dir version_diff new_dir
    ) with _ -> raise (ServerError "Unexpected response")
  in Lwt_main.run (Lwt.pick [request; timeout ()])

let sync () =
  let config = load_config () in
  if check_invalid_filename () <> [] then
    print_endline ("Please resolve local merge"
                   ^ " conflict before syncing with the server.")
  else
    let print_modified m_list =
      if m_list = [] then ()
      else begin
        print_endline "Following file(s) have sync conflicts with the server:";
        List.iter (
          fun (file, deleted)->
            if deleted then
              print_endline ("# " ^ file ^ " - deleted")
            else
              print_endline ("# " ^ file)
        ) m_list;
        print_endline "These files have been renamed to [*_local].";
        if List.exists (fun (_,deleted) -> deleted) m_list then
          print_endline "Files with [- deleted] appended have updates \
                         from the server, yet are deleted locally and are not \
                         renamed with the [*_local] suffix. Please delete \
                         them again if you still wish to do so."
      end
    in
    print_endline "Sync...";
    match get_update_diff config with
    | (m_list, []) ->
      print_modified m_list
    | (m_list, diff_list) ->
      print_modified m_list;
      let version_diff = {
        prev_version = config.version;
        cur_version = config.version;
        edited_files = diff_list;
      } in
      let new_v = post_local_diff config version_diff in
      print_endline "Push local updates to the server.";
      update_config {config with version=new_v};
      print_endline ("Update current version to " ^ (string_of_int new_v) ^ ".")

let init url token =
  (* Makes a dummy call to check if the url is a caml_sync server *)
  let open Uri in
  let uri = Uri.of_string  ("//"^url) in
  let uri = with_path uri "version" in
  let uri = with_scheme uri (Some "http") in
  let uri = Uri.add_query_param' uri ("token", token) in
  let request =
    Client.get uri >>= fun (resp, body) ->
    let code = resp |> Response.status |> Code.code_of_status in
    (* First checks if pass token test by the response status code *)
    if code = 401 then
      `Empty |> Cohttp_lwt.Body.to_string >|= fun _ -> raise Unauthorized
    else
    if code <> 200 then
      `Empty |> Cohttp_lwt.Body.to_string >|= fun _ ->
      raise (ServerError "unexpected response code")
    else
      body |> Cohttp_lwt.Body.to_string >|= fun body ->
      match (from_string body) with
      | `O (json) ->
        begin match List.assoc_opt "version" json with
          | Some v ->
            if Sys.file_exists ".config" then
              print_endline ("[.config] already exsits.\n" ^
                             "It seems like the current directory has already \
                              been initialized into a camlsync client \
                              directory.")
            else
              let config = {
                client_id = "client";
                url = url;
                token = token;
                version = 0
              } in
              update_config config;
              remove_dir_and_files hidden_dir;
              Unix.mkdir hidden_dir 0o770;
              print_endline ("Successfully initialize the camlsync client.");
              sync ()
          | None ->
            raise (ServerError ("The address you entered does"
                                ^ " not seem to be a valid caml_sync address"))
        end
      | _ -> raise (ServerError ("The address you entered does"
                                 ^ " not seem to be a valid caml_sync address"))
  in Lwt_main.run (Lwt.pick [request; timeout ()])

(* [delete_all_local_files ()] delete all merge conflict files.
 * These files end up with "_local". *)
let delete_all_local_files () =
  let dir = "." in
  let d_handle = Unix.opendir dir in
  let set = search_dir d_handle StrSet.add StrSet.empty []
      dir (List.map (fun ele -> "_local" ^ ele) valid_extensions) in
  StrSet.iter (fun ele -> delete_file ele) set

(* [delete_history_folders ()] delete all backup history folders.
 * These folders start with "camlsync_history_" *)
let delete_history_folders () =
  let rec delete_history_folder dir =
    match Unix.readdir dir with
    | exception End_of_file -> Unix.closedir dir
    | p_name ->
      let rela_name = "./" ^ p_name in
      (if has_prefix_in_lst rela_name [history_dir_prefix] then
         remove_dir_and_files rela_name
       else ());
      delete_history_folder dir in
  let dir = Unix.opendir "." in
  delete_history_folder dir

(* usage:
 *  caml_sync init <url> <token> ->
 *    inits the current directory as a client directory
 *  caml_sync ->
 *    syncs files in local directories with files in server
*)
let main () =
  if Array.length Sys.argv = 1 then
    sync ()
  else match Array.get Sys.argv 1 with
    | "init" ->
      begin try (
        if (Array.length Sys.argv) = 4 then
          init (Array.get Sys.argv 2) (Array.get Sys.argv 3)
        else init "127.0.0.1:8080" "default" )
        with Unix.Unix_error _ ->
          raise (ServerError "Cannot connect to the server.")
      end
    | "clean" ->
      begin try Sys.remove ".config";
          remove_dir_and_files ".caml_sync";
          delete_all_local_files ();
          delete_history_folders () with
      | Sys_error e -> raise Not_Initialized
      end;
      print_endline "All local conflict files, history version folders, \
                     camlsync hidden files and folders have been removed."
    | "checkout" ->
      let curr_handle =
        try Unix.opendir "." with | _ -> raise Not_found
      in
      search_dir curr_handle (List.cons) [] [] "." valid_extensions
      |> List.filter (fun file -> not (has_prefix_in_lst file unwanted_strs) )
      |> List.iter delete_file;
      let hidden_handle =
        try Unix.opendir hidden_dir with | _ -> raise Not_Initialized
      in
      let from_files =
        search_dir hidden_handle (List.cons) [] []
          hidden_dir valid_extensions in
      let to_files =
        List.map (fun file -> replace_prefix file hidden_dir ".") from_files in
      copy_files from_files to_files
    | "status" ->
      let cur_version = (load_config ()).version in
      let f_diffs = compare_working_backup () in
      print_endline ("Current version: " ^ (string_of_int cur_version));
      if List.length f_diffs = 0 then print_endline "working directory clean"
      else List.iter (fun {file_name; is_deleted}
                       -> let f_status =
                            if is_deleted then "deleted" else "modified" in
                         print_endline (f_status ^ ": " ^  file_name)) f_diffs
    | "history" ->
      let fmt timestamp =
        let open Unix in
        let tm = timestamp |> localtime in
        (List.nth week tm.tm_wday) ^ " " ^
        (List.nth month tm.tm_mon) ^ " " ^
        (string_of_int tm.tm_mday) ^ " " ^
        (string_of_int (tm.tm_year+1900)) ^ " " ^
        (string_of_int tm.tm_hour) ^ ":" ^ (string_of_int tm.tm_min) in
      if Array.length Sys.argv = 3 && (Array.get Sys.argv 2) = "list" then
        let history_log = (history_list (load_config ())) in
        List.iter
          (fun (hist:history):unit -> print_endline
              (
                "Version: "^(string_of_int hist.version)
                ^"; Time: "^(fmt hist.timestamp)
              )
          )
          history_log.log;
        print_endline "Type 'camlsync history i' to download version i backup."
      else if Array.length Sys.argv = 3 && Sys.argv.(2) = "clean" then
        (delete_history_folders ();
         print_endline "All history version folders have been removed.")
      else if Array.length Sys.argv = 3 then
        let v =
          try int_of_string (Array.get Sys.argv 2)
          with _ -> raise (Invalid_argument "The version number must be an \
                                             integer which is larger than or \
                                             equal to 1.")
        in
        if v < 1 then raise (Invalid_argument "The version number must be an \
                                               integer which is larger than \
                                               or equal to 1.")
        else begin time_travel (load_config ()) v;
          let v_s = Array.get Sys.argv 2 in
          print_endline ("Download your version " ^ v_s
                         ^ " backup to ./camlsync_history_version_"
                         ^ v_s ^ ".") end
      else raise (Invalid_argument ("Invalid arguments.\n" ^ usage))
    | "help" ->
      print_endline usage
    | "conflict" ->
      if Array.length Sys.argv = 2 then
        let conflicts = check_invalid_filename () in
        if conflicts = [] then
          print_endline "There is nothing conflict."
        else
          begin
            print_endline "Following file(s) have sync \
                           conflicts with the server:";
            List.iter (fun ele -> print_endline ("# " ^ ele) ) conflicts
          end
      else if Array.length Sys.argv = 3 && Sys.argv.(2) = "clean"
      then begin delete_all_local_files ();
        print_endline "All local conflict files have been removed." end
      else raise (Invalid_argument ("Invalid arguments.\n" ^ usage))
    | _ -> raise (Invalid_argument ("Invalid arguments.\n" ^ usage))
