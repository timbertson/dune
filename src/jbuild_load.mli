open Stdune

module Jbuilds : sig
  type t

  val eval
    :  t
    -> context:Context.t
    -> (Path.t * Dune_project.t * Jbuild.Stanzas.t) list Fiber.t
end

type conf =
  { file_tree : File_tree.t
  ; jbuilds   : Jbuilds.t
  ; packages  : Package.t Package.Name.Map.t
  ; projects  : Dune_project.t list
  }

val load
  :  ?extra_ignored_subtrees:Path.Set.t
  -> ?ignore_promoted_rules:bool
  -> unit
  -> conf
