open! Import

module Dune_file = struct
  module Plain = struct
    type t =
      { path          : Path.t
      ; mutable sexps : Sexp.Ast.t list
      }
  end

  type t =
    | Plain of Plain.t
    | Ocaml_script of Path.t

  let path = function
    | Plain x -> x.path
    | Ocaml_script  p -> p

  let ocaml_script_prefix = "(* -*- tuareg -*- *)"
  let ocaml_script_prefix_len = String.length ocaml_script_prefix

  let extract_ignored_subdirs =
    let stanza =
      let open Sexp.Of_sexp in
      let sub_dir sexp =
        let dn = string sexp in
        if Filename.dirname dn <> Filename.current_dir_name ||
           match string sexp with
           | "" | "." | ".." -> true
           | _ -> false
        then
          of_sexp_errorf sexp "Invalid sub-directory name %S" dn
        else
          dn
      in
      sum
        [ cstr "ignored_subdirs" (list sub_dir @> nil) String.Set.of_list
        ]
    in
    fun sexps ->
      let ignored_subdirs, sexps =
        List.partition_map sexps ~f:(fun sexp ->
          match (sexp : Sexp.Ast.t) with
          | List (_, (Atom (_, A "ignored_subdirs") :: _)) ->
            Left (stanza sexp)
          | _ -> Right sexp)
      in
      let ignored_subdirs =
        List.fold_left ignored_subdirs ~init:String.Set.empty ~f:String.Set.union
      in
      (ignored_subdirs, sexps)

  let load file =
    Io.with_file_in file ~f:(fun ic ->
      let open Sexp in
      let state = Parser.create ~fname:(Path.to_string file) ~mode:Many in
      let buf = Bytes.create Io.buf_len in
      let rec loop stack =
        match input ic buf 0 Io.buf_len with
        | 0 -> stack
        | n -> loop (Parser.feed_subbytes state buf ~pos:0 ~len:n stack)
      in
      let finish stack =
        let sexps = Parser.feed_eoi state stack in
        let ignored_subdirs, sexps = extract_ignored_subdirs sexps in
        (Plain { path = file; sexps },
         ignored_subdirs)
      in
     let rec loop0 stack i =
        match input ic buf i (Io.buf_len - i) with
        | 0 ->
          finish (Parser.feed_subbytes state buf ~pos:0 ~len:i stack)
        | n ->
          let i = i + n in
          if i < ocaml_script_prefix_len then
            loop0 stack i
          else if Bytes.sub_string buf 0 ocaml_script_prefix_len
                    [@warning "-6"]
                  = ocaml_script_prefix then
            (Ocaml_script file, String.Set.empty)
          else
            let stack = Parser.feed_subbytes state buf ~pos:0 ~len:i stack in
            finish (loop stack)
      in
      loop0 Parser.Stack.empty 0)
end

let load_jbuild_ignore path =
  List.filteri (Io.lines_of_file path) ~f:(fun i fn ->
    if Filename.dirname fn = Filename.current_dir_name then
      true
    else begin
      Loc.(warn (of_pos ( Path.to_string path
                        , i + 1, 0
                        , String.length fn
                        ))
             "subdirectory expression %s ignored" fn);
      false
    end)
  |> String.Set.of_list

module Dir = struct
  type t =
    { path     : Path.t
    ; ignored  : bool
    ; contents : contents Lazy.t
    }

  and contents =
    { files     : String.Set.t
    ; sub_dirs  : t String.Map.t
    ; dune_file : Dune_file.t option
    ; project   : Dune_project.t option
    }

  let contents t = Lazy.force t.contents

  let path t = t.path
  let ignored t = t.ignored

  let files     t = (contents t).files
  let sub_dirs  t = (contents t).sub_dirs
  let dune_file t = (contents t).dune_file
  let project   t = (contents t).project

  let file_paths t =
    Path.Set.of_string_set (files t) ~f:(Path.relative t.path)

  let sub_dir_names t =
    String.Map.foldi (sub_dirs t) ~init:String.Set.empty
      ~f:(fun s _ acc -> String.Set.add acc s)

  let sub_dir_paths t =
    String.Map.foldi (sub_dirs t) ~init:Path.Set.empty
      ~f:(fun s _ acc -> Path.Set.add acc (Path.relative t.path s))

  let rec fold t ~traverse_ignored_dirs ~init:acc ~f =
    if not traverse_ignored_dirs && t.ignored then
      acc
    else
      let acc = f t acc in
      String.Map.fold (sub_dirs t) ~init:acc ~f:(fun t acc ->
        fold t ~traverse_ignored_dirs ~init:acc ~f)
end

type t =
  { root : Dir.t
  ; dirs : (Path.t, Dir.t) Hashtbl.t
  }

let root t = t.root

let ignore_file fn ~is_directory =
  fn = "" || fn = "." ||
  (is_directory && (fn.[0] = '.' || fn.[0] = '_')) ||
  (fn.[0] = '.' && fn.[1] = '#')

module File = struct
  type t =
    { ino : int
    ; dev : int
    }

  let compare a b =
    match Int.compare a.ino b.ino with
    | Eq -> Int.compare a.dev b.dev
    | ne -> ne

  let dummy = { ino = 0; dev = 0 }

  let of_stats (st : Unix.stats) =
    { ino = st.st_ino
    ; dev = st.st_dev
    }
end

module File_map = Map.Make(File)

let load ?(extra_ignored_subtrees=Path.Set.empty) path =
  let rec walk path ~dirs_visited ~project ~ignored : Dir.t =
    let contents = lazy (
      let files, sub_dirs =
        Path.readdir path
        |> List.filter_partition_map ~f:(fun fn ->
          let path = Path.relative path fn in
          let is_directory, file =
            match Unix.stat (Path.to_string path) with
            | exception _ -> (false, File.dummy)
            | { st_kind = S_DIR; _ } as st ->
              (true, File.of_stats st)
            | _ ->
              (false, File.dummy)
          in
          if ignore_file fn ~is_directory then
            Skip
          else if is_directory then
            Right (fn, path, file)
          else
            Left fn)
      in
      let files = String.Set.of_list files in
      let project =
        match Dune_project.load ~dir:path ~files with
        | Some _ as x -> x
        | None        -> project
      in
      let dune_file, ignored_subdirs =
        if ignored then
          (None, String.Set.empty)
        else
          let dune_file, ignored_subdirs =
            match List.filter ["dune"; "jbuild"] ~f:(String.Set.mem files) with
            | [] -> (None, String.Set.empty)
            | [fn] ->
              let dune_file, ignored_subdirs =
                Dune_file.load (Path.relative path fn)
              in
              (Some dune_file, ignored_subdirs)
            | _ ->
              die "Directory %s has both a 'dune' and 'jbuild' file.\n\
                   This is not allowed"
                (Path.to_string_maybe_quoted path)
          in
          let ignored_subdirs =
            if String.Set.mem files "jbuild-ignore" then
              String.Set.union ignored_subdirs
                (load_jbuild_ignore (Path.relative path "jbuild-ignore"))
            else
              ignored_subdirs
          in
          (dune_file, ignored_subdirs)
      in
      let sub_dirs =
        List.fold_left sub_dirs ~init:String.Map.empty
          ~f:(fun acc (fn, path, file) ->
            let dirs_visited =
              if Sys.win32 then
                dirs_visited
              else
                match File_map.find dirs_visited file with
                | None -> File_map.add dirs_visited file path
                | Some first_path ->
                  die "Path %s has already been scanned. \
                       Cannot scan it again through symlink %s"
                    (Path.to_string_maybe_quoted first_path)
                    (Path.to_string_maybe_quoted path)
            in
            let ignored =
              ignored
              || String.Set.mem ignored_subdirs fn
              || Path.Set.mem extra_ignored_subtrees path
            in
            String.Map.add acc fn
              (walk path ~dirs_visited ~project ~ignored))
      in
      { Dir. files; sub_dirs; dune_file; project })
    in
    { path
    ; contents
    ; ignored
    }
  in
  let root =
    walk path
      ~dirs_visited:(File_map.singleton
                       (File.of_stats (Unix.stat (Path.to_string path)))
                       path)
      ~ignored:false
      ~project:None
  in
  let dirs = Hashtbl.create 1024      in
  Hashtbl.add dirs Path.root root;
  { root; dirs }

let fold t ~traverse_ignored_dirs ~init ~f =
  Dir.fold t.root ~traverse_ignored_dirs ~init ~f

let rec find_dir t path =
  if not (Path.is_local path) then
    None
  else
    match Hashtbl.find t.dirs path with
    | Some _ as res -> res
    | None ->
      match
        let open Option.O in
        Path.parent path
        >>= find_dir t
        >>= fun parent ->
        String.Map.find (Dir.sub_dirs parent) (Path.basename path)
      with
      | Some dir as res ->
        Hashtbl.add t.dirs path dir;
        res
      | None ->
        (* We don't cache failures in [t.dirs]. The expectation is
           that these only happen when the user writes an invalid path
           in a jbuild file, so there is no need to cache them. *)
        None

let files_of t path =
  match find_dir t path with
  | None -> Path.Set.empty
  | Some dir ->
    Path.Set.of_string_set (Dir.files dir) ~f:(Path.relative path)

let file_exists t path fn =
  match find_dir t path with
  | None -> false
  | Some dir -> String.Set.mem (Dir.files dir) fn

let dir_exists t path = Option.is_some (find_dir t path)

let exists t path =
  dir_exists t path ||
  file_exists t (Path.parent_exn path) (Path.basename path)

let files_recursively_in t ?(prefix_with=Path.root) path =
  match find_dir t path with
  | None -> Path.Set.empty
  | Some dir ->
    Dir.fold dir ~init:Path.Set.empty ~traverse_ignored_dirs:true
      ~f:(fun dir acc ->
        let path = Path.append prefix_with (Dir.path dir) in
        String.Set.fold (Dir.files dir) ~init:acc ~f:(fun fn acc ->
          Path.Set.add acc (Path.relative path fn)))
