# A simple minimal programming language

> Everything in this readme is mostly functional.

Welcome to `avon`, a transpiler; takes code as input passes it through a `parser` and emits `lua` compiled byte-code directly.

**Requires** Lua 5.3/5.4  or LuaJIT (not vanilla 5.1, the output uses `goto`).
Run it under LuaJIT for ~5–14× on hot code: `luajit ./nova prog.nova`.

> Note: under LuaJIT (doubles only) integers are exact to 2⁵³ and bitwise is 32-bit; Lua 5.4 gives full 64-bit.

# Avon - 艾汶

`avon` is a modern simplified C++ built on Lua, designed for clarity and modern expression.
It uses `fn` for function declarations, first class multiple return times and omits parentheses for conditional statements, and optional curly braces for single expression functions, too.
Mostly tested only on **Unix** systems.

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
break    continue switch   case     default
enum     typedef
try      catch    except   throw
```

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

```cpp
fn main() {
  print("Hello, " + name)
}
```

*curly braces are optional for single expressions for functions, too*

```cpp
fn main()
  print("Hello, " + name)
```

natively supports multiple return values just likr arguments, too

```cpp
fn int, int test(int x, int y)
  return x, y

int v, error = test(x, y)
```

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

> A minimal language earns its minimalism by not rebuilding what the host already does well.

This project was originally developped by @rxrbln but had very different goals (codegen, RISC-V).
But this idea was basically re-inventing Lua's contributors' work, which was impractical.
I thought the idea was elegant and generalized it for **x86_64 target only**, straight `load()` to Lua.

> It also was missing a lot of features that were described in the documentation. Which now mostly work.
