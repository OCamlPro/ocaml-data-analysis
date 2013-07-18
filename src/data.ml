open Utils

(* use generative applications to have a new type each time *)
module Id = MakeId(struct end)
module Constant = MakeId(struct end)
module F = MakeId(struct end)

type id = Id.t

type constant = Constant.t

module Constants = Set.Make (struct type t = constant let compare = compare end)

type simple = Top | Constants of Constants.t

type tag = int

type f = F.t

module Ints = Set.Make (struct type t = int let compare = compare end)
module Intm = Map.Make (struct type t = int let compare = compare end)

module Tagm = Map.Make (struct type t = tag let compare = compare end)

module Idm = Map.Make (struct type t = id let compare = compare end)
module Ids = Set.Make (struct type t = id let compare = compare end)

module Fm = Map.Make (struct type t = f let compare = compare end)

(* The data *)

type data =
  {
    top : bool;
    int : simple;
    float : simple;
    string : simple;
    floata : simple;
    i32 : simple;
    i64 : simple;
    inat : simple;
    cp : Ints.t;
    blocks : Ids.t array Intm.t Tagm.t; (* referenced by tag, then by size *)
    f : Ids.t array Fm.t;
  }

let simple_bottom = Constants Constants.empty

let bottom =
  {
    top = false;
    int = simple_bottom;
    float = simple_bottom;
    string = simple_bottom;
    floata = simple_bottom;
    i32 = simple_bottom;
    i64 = simple_bottom;
    inat = simple_bottom;
    cp = Ints.empty;
    blocks = Tagm.empty;
    f = Fm.empty;
  }


(* environment management *)

type environment =
  | Bottom
  | Env of data Idm.t

let is_bottom_env = function
  | Bottom -> true
  | _ -> false

let bottom_env = Bottom
let empty_env = Env Idm.empty

let set_env id data = function
  | Bottom ->
    (* not sure this should really forbidden, but this may help avoid
       some bugs *)
    failwith "bottom should never be assigned"
  | Env env -> Env (Idm.add id data env)

let get_env id = function
  | Bottom -> bottom
  | Env env ->
    try Idm.find id env
    with Not_found -> bottom

let reg_env data env =
  let i = Id.create () in
  ( set_env i data env, i)


(* simple functions and values *)

let int_singleton const =
  { bottom with int = Constants (Constants.singleton const) }


(* bottom test *)

let is_bottom_simple = function
  | Top -> false
  | Constants c -> Constants.is_empty c

let is_bottom env { top; int; float; string; floata; i32;
                i64; inat; cp; blocks; f } =
  top = false && is_bottom_simple int && is_bottom_simple float &&
  is_bottom_simple string && is_bottom_simple floata &&
  is_bottom_simple i32 && is_bottom_simple i64 &&
  is_bottom_simple inat &&
  Ints.is_empty cp && Tagm.is_empty blocks && Fm.is_empty f

(* union *)

(* let register_id (_:data) = Id.create () *)
(* let get_id (_:id) = bottom *)

let union_simple a b = match a, b with
  | Top, _ | _, Top -> Top
  | Constants s, Constants s' -> Constants ( Constants.union s s')


let rec union env a b =
  let blocks =
    Tagm.merge
      begin
	fun _ a b ->
	  match a, b with
	  | a, None | None, a -> a
	  | Some is1, Some is2 ->
	    Some (
	      Intm.merge
		(fun _ a b ->
		  match a, b with
		  | a, None | None, a -> a
		  | Some s1, Some s2 -> Some ( Array.mapi (fun i i1 -> Ids.union i1 s2.(i)) s1)
		)
		is1 is2
	    )
      end
      a.blocks b.blocks in
  let f = Fm.merge
    begin
      fun _ a b ->
	match a, b with
	| a, None | None, a -> a
	| Some i1, Some i2 -> Some ( Array.mapi (fun i i1i -> Ids.union i1i i2.(i)) i1 )
    end
    a.f b.f;
  in
  env,
  {
    top = a.top || b.top;
    int = union_simple a.int b.int;
    float = union_simple a.float b.float;
    string = union_simple a.string b.string;
    floata = union_simple a.floata b.floata;
    i32 = union_simple a.i32 b.i32;
    i64 = union_simple a.i64 b.i64;
    inat = union_simple a.inat b.inat;
    cp = Ints.union a.cp b.cp;
    blocks;
    f;
  }

and union_id env i1 i2 =
  let ( env, u) = union env (get_env i1 env) (get_env i2 env) in
  reg_env u env
  

(* intersection *)

let intersection_simple a b = match a, b with
  | Top, a | a, Top -> a
  | Constants s, Constants s' ->
    Constants ( Constants.inter s s')

let union_ids env ids = Ids.fold (fun a ( env, b) -> union env (get_env a env) b) ids ( env, bottom)

let included_simple a b = match a, b with
  | Top, _ | _, Top -> true
  | Constants s, Constants s' -> Constants.exists ( fun a -> Constants.mem a s') s

let array2_forall f a b =
  let l = Array.length a in
  let rec aux i = i = l || f a.(i) b.(i) || aux (succ i) in
  aux 0

let rec included env i1 i2 =
  let a = get_env i1 env
  and b = get_env i2 env in
  if is_bottom env b
  then is_bottom env a
  else 
    b.top
    || a.top
    || included_simple a.int b.int
    || included_simple a.float b.float
    || included_simple a.string b.string
    || included_simple a.floata b.floata
    || included_simple a.i32 b.i32
    || included_simple a.i64 b.i64
    || included_simple a.inat b.inat
    || Ints.exists (fun a -> Ints.mem a b.cp) a.cp
    || Tagm.exists
      (fun k a ->
	try
	  let b = Tagm.find k b.blocks in
	  Intm.exists
	    (fun k a ->
	      let b = Intm.find k b in
	      array2_forall
		(fun a b ->
		  Ids.exists
		    (fun a -> Ids.exists ( included env a) b)
		    a
		)
		a b
	    ) a
	with Not_found -> false) a.blocks
    || Fm.exists
      (fun k a ->
	try
	  let b = Fm.find k b.f in
	  array2_forall
	    (fun a b ->
	      Ids.exists
		(fun a -> Ids.exists ( included env a) b)
		a
	    ) a b
	with Not_found -> false) a.f
      
      
let intersect_noncommut env a b =
  (* keeps the ids in a that are possibly compatible with b *)
  if a.top then (env, b)
  else if b.top then (env, a)
  else
    let blocks = 
      Tagm.merge
	begin
	  fun _ a b ->
	    match a, b with
	    | _, None | None, _ -> None
	    | Some is1, Some is2 ->
	      Some (
		Intm.merge
		  (fun _ a b ->
		    match a, b with
		    | _, None | None, _ -> None
		    | Some s1, Some s2 ->
		      Some
			(
			  Array.mapi
			    (fun i i1 ->
			      ( Ids.filter (fun id -> Ids.exists ( included env id) s2.(i)) i1)
			    )
			    s1
			)
		  )
		  is1 is2
	      )
	end
	a.blocks b.blocks
    in
    let f =
      Fm.merge
	begin
	  fun _ a b ->
	    match a, b with
	    | _, None | None, _ -> None
	    | Some a, Some b ->
	      Some (
		Array.mapi
		  (fun i a ->
		    Ids.filter
		      (fun a ->
			Ids.exists (included env a) b.(i)
		      ) a
		  ) a
	      )
	end
	a.f b.f
    in
    env,
    { top = false;
      int = intersection_simple a.int b.int;
      float = intersection_simple a.float b.float;
      string = intersection_simple a.string b.string;
      floata = intersection_simple a.floata b.floata;
      i32 = intersection_simple a.i32 b.i32;
      i64 = intersection_simple a.i64 b.i64;
      inat = intersection_simple a.inat b.inat;
      cp = Ints.inter a.cp b.cp;
      blocks;
      f;
    }
  


(* let rec intersection env a b = *)
(*   if a.top then (env, b) *)
(*   else if b.top then (env, a) *)
(*   else *)
(*     let ( env, blocks) =  *)
(*       Tagm.merge *)
(* 	begin *)
(* 	  fun _ a b -> *)
(* 	    match a, b with *)
(* 	    | _, None | None, _ -> None *)
(* 	    | Some is1, Some is2 -> *)
(* 	      Some ( *)
(* 		Intm.merge *)
(* 		  (fun _ a b -> *)
(* 		    match a, b with *)
(* 		    | _, None | None, _ -> None *)
(* 		    | Some s1, Some s2 -> *)
(* 		      Some *)
(* 			( *)
(* 			  Array.mapi *)
(* 			    (fun i i1 -> *)
(* 			      let inter = intersection env ( union_ids env i1) ( union_ids env s2.(i)) in *)
(* 			      Ids.singleton ( register_id inter) *)
(* 			    ) *)
(* 			    s1 *)
(* 			) *)
(* 		  ) *)
(* 		  is1 is2 *)
(* 	      ) *)
(* 	end *)
(* 	a.blocks b.blocks *)
(*     in *)
(*     let ( env, f) = *)
(*       Fm.merge *)
(* 	begin *)
(* 	  fun _ a b -> *)
(* 	    match a, b with *)
(* 	    | _, None | None, _ -> None *)
(* 	    | Some i1, Some i2 -> *)
(* 	      Some ( *)
(* 		Array.mapi (fun i i1i -> *)
		  
(* 		  let inter = intersection *)
(* 		    env *)
(* 		    ( union_ids i1i) *)
(* 		    ( union_ids i2.(i)) *)
(* 		  in Ids.singleton ( register_id inter) *)
(* 		) i1 *)
(* 	      ) *)
(* 	end *)
(* 	a.f b.f; *)
(*     in *)
(*     env, *)
(*     { top = false; *)
(*       int = intersection_simple a.int b.int; *)
(*       float = intersection_simple a.float b.float; *)
(*       string = intersection_simple a.string b.string; *)
(*       floata = intersection_simple a.floata b.floata; *)
(*       i32 = intersection_simple a.i32 b.i32; *)
(*       i64 = intersection_simple a.i64 b.i64; *)
(*       inat = intersection_simple a.inat b.inat; *)
(*       cp = Ints.inter a.cp b.cp; *)
(*       blocks; *)
(*       f; *)
(*     } *)

(* and intersection_id env i1 i2 = *)
(*   register_id ( intersection env (get_id i1) (get_id i2)) *)