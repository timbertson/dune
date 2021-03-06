(** [Ordered_set_lang.t] is a sexp-based representation for an ordered list of strings,
    with some set like operations. *)

open Import

type t
val t : t Sexp.Of_sexp.t

(** Return the location of the set. [loc standard] returns [None] *)
val loc : t -> Loc.t option

(** Value parsed from elements in the DSL *)
module type Value = sig
  type t
  type key
  val key : t -> key
end

module type Key = sig
  type t
  val compare : t -> t -> Ordering.t
  module Map : Map.S with type key = t
end

module type S = sig
  (** Evaluate an ordered set. [standard] is the interpretation of [:standard]
      inside the DSL. *)
  type value
  type 'a map

  val eval
    :  t
    -> parse:(loc:Loc.t -> string -> value)
    -> standard:value list
    -> value list

  (** Same as [eval] but the result is unordered *)
  val eval_unordered
    :  t
    -> parse:(loc:Loc.t -> string -> value)
    -> standard:value map
    -> value map
end

module Make(Key : Key)(Value : Value with type key = Key.t)
  : S with type value = Value.t
       and type 'a map = 'a Key.Map.t

val standard : t
val is_standard : t -> bool

module Unexpanded : sig
  type expanded = t
  type t
  val t : t Sexp.Of_sexp.t
  val sexp_of_t : t Sexp.To_sexp.t
  val standard : t

  val field : ?default:t -> string -> t Sexp.Of_sexp.record_parser

  val has_special_forms : t -> bool

  (** List of files needed to expand this set *)
  val files : t -> f:(String_with_vars.t -> string) -> String.Set.t

  (** Expand [t] using with the given file contents. [file_contents] is a map from
      filenames to their parsed contents. Every [(:include fn)] in [t] is replaced by
      [Map.find files_contents fn]. Every element is converted to a string using [f]. *)
  val expand
    :  t
    -> files_contents:Sexp.Ast.t String.Map.t
    -> f:(String_with_vars.t -> string)
    -> expanded
end with type expanded := t

module String : S with type value = string and type 'a map = 'a String.Map.t
