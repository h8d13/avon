# A simple minimal programming language

> Everything in this readme is mostly functional.

Welcome to `avon`, a transpiler; takes code as input passes it through a `parser` and emits `lua` compiled byte-code directly.

See https://www.lua.org/manual/5.5/

**Requires** Lua 5.3+  or LuaJIT (not vanilla 5.1, the output uses `goto`).
Run it under LuaJIT for ~5–14× on hot code: `luajit ./nova prog.nova`.

> Note: under LuaJIT (doubles only) integers are exact to 2⁵³ and bitwise is 32-bit; Lua 5.4/5.5 gives full 64-bit.

# Avon - 艾汶

`avon` is a modern simplified C++ built on Lua, designed for clarity and modern expression.
It uses `fn` for function declarations, first class multiple return times and omits parentheses for conditional statements, and optional curly braces for single expression functions, too.
Mostly tested only on **Unix** systems.

> It is token based and not indent. It supports `{};` notations without enforcing them.

---

## 📃 Comments

```cpp
// Single line comments

/*
Multi-line
comment
*/
```

---

## 🧠 Keywords

```
fn       if       else     for      return
break    continue
switch   case     default
enum     typedef
try      catch    except   throw
import
```

### Aliasing words

Any word can be re-spelled per file with a `__<target> = <alias>` directive
at the top. The `__` prefix is the namespace for touching internals.

```cpp
__return = ret      // keyword
__fn     = func     // keyword
__print  = p        // host function

func int add(int a, int b) {
	p("adding");
	ret a + b
}
```

`target` is a keyword (the rewrite is treated as that keyword) or any other
identifier such as a host/user function name (the rewrite stays an
identifier). A non-keyword target must still resolve to something real (a
function, a host name, a binding): the rewritten name goes through the same
unbound-name check as any identifier, so a typo'd function target is a compile
error, not a silent runtime nil-call. An alias may not be an existing keyword.

The marker itself is rebindable. `<marker>pragma = <punct>` (or the short
`<marker>pg = <punct>`) switches it for the lines that follow, so you can trade
`__` for a terser symbol. `__` is the irreducible root (something has to
bootstrap the rest).

```cpp
__pragma = $$
$$fn     = f
$$return = r

f int main() { r 42 }
```

Several directives may also share a line, `;`-separated (the spaces around `=`
are optional). A line is treated as directives only when *every* segment is one,
so ordinary code is never affected; the marker may even be rebound mid-line.

```cpp
__pragma = @; @fn = f; @return = r

f int main() { r 42 }
```

Scope is the file (aliases do not leak across `import`). To share aliases
project-wide, put the directives in a `.novapre` file at the entry
directory; every compiled file (entry and imports) inherits them. For
*type* names use `typedef` instead.

---

## 🔤 Literals

```cpp
123         // integer
3.14        // float
"hello"     // string
'c'         // char
true, false // boolean
null        // null value
```

---

## 🧮 Operators

```
+   -   *   /   %         // arithmetic
==  !=  <   >   <=  >=    // comparison
&&  ||  !                 // logical
&   |   ^   ~   <<  >>    // bitwise
=   +=  -=  *=  /=  ...   // assignment
```

---

## 🏗️ Functions

Return type(s) come after `fn`, before the name, and are required.

```cpp
str name = "Nova";

fn int main() {
	print("Hello, " + name)
}
```

*curly braces are optional for single expressions for functions, too*

natively supports multiple return values just like arguments, too

```cpp
fn int, int test(int x, int y)
	return x, y

int v, error = test(x, y)
```

---

## 🌍 File-scope variables

Declarations at the top level are file-scope: every function in the file
sees them, and any function may mutate them. Initializers run once, after
the functions are defined, so they may call them. Declaration semicolons
are optional, and several declarations can share a line.

```cpp
int hits = 0
str sep = ", "
int a, b = pair()   // calls a function defined below

fn int, int pair() { return 3, 4 }

fn int bump() {
	hits += 1;
	return hits
}
```

Params and locals shadow a file-scope name. Like aliases, scope is the
file: a module exports only its functions, never its variables.

---

## 🔁 Control Structures

### If/Else

```cpp
if x > 0 {
	print("Positive")
} else {
	print("Negative or zero")
}
```

### For (one one way to loop)

```cpp
for int i = 0; i < 10; ++i {
	print(i)
}
```

*for iterators and generators, too*

```cpp
for string s = it.next() {
	print(i)
}
```

---

## 🧱 Data Structures

### Enum

```cpp
enum Color {
	Red,
	Green,
	Blue,
}
```

### Array

Fixed-size arrays declare with `[N]` after the type, index with `[i]`.

```cpp
int[10] xs;
xs[0] = 1;
int v = xs[i + 1];
```

Indexing chains for nested arrays and call results.

```cpp
int v = grid[a][b];
int w = row()[0];
```

---

## 🧩 Match Expression

```cpp
switch color {
	case Red:
		print("Stop")
  	case Green:
		print("Go")
  	default:
		print("Wait")
}
```

---

## ⚠️ Exceptions

Nova supports basic exception handling using `throw` and `catch` (also
spelled `try`/`except`).

### Throwing an Exception

```cpp
fn risky()
	throw "Something went wrong"
```

### Catching Exceptions

```cpp
fn main() {
	try
		risky()
  	catch err
		print("Error was: " + err)
}
```

## 📦 Modules

`import <module>` exposes a host module's functions to Nova as
`module.fn(...)`. A stdlib table works out of the box:

`import <module> as <alias>` binds the same module under a different prefix:

```cpp
import math as m

fn int hypot(int a, int b) {
	return m.sqrt(a * a + b * b)
}
```

A `luarocks` package is no different -- install it so it's on Lua's path,
then `import` it (run under the Lua version the rock was built for):

```cpp
import cjson

fn str roundtrip() {
	return cjson.encode(cjson.decode("[10, 20, 30]"))
}
```

`import` also loads other Nova files (`.nova`, or the extensionless file of
that name); dotted paths are folders under the project root, and a name with
no matching file falls back to `require`:

```cpp
import geom         // root/geom.nova    -> geom.fn(...)
import a.b.c as g   // root/a/b/c.nova    -> g.fn(...)
```

---

## Additional details

> A minimal language earns its minimalism by not rebuilding what the host already does well.

This project was originally developped by @rxrbln but had very different goals (codegen, RISC-V).
But this idea was basically re-inventing Lua's contributors' work, which was impractical.
I thought the idea was elegant and generalized it for **x86_64 target only**, straight `load()` to Lua.

> It also was missing a lot of features that were described in the documentation. Which now mostly work.

Used `stylua` to enforce style accross the cb.
