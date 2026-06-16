# A simple minimal programming language

In a world where new hyped language compilers and runtime std libraries are implemented in 4GB of sources, it's time for a reset.

At the foundation is Nýr, a portable micro-IR (µIR) designed for efficient and flexible code generation. Built on top of Nýr is Nova, a new minimal high-level language that embraces modern programming principles. Together, Nýr and Nova represent a bold step toward a leaner, more elegant future in software development.
Nava isn't just a language it's a philosophy: that the complexity of modern systems is not a necessity but a choice. Nava chooses minimalism, portability and readability.

# 🛰️ Nova Language Syntax Sheet

Nova is a modern simplified C++ built on Lua, designed for clarity and modern expression. It uses `fn` for function declarations, first class multiple return times and omits parentheses for conditional statements, and optional curly braces for single expression functions, too.

---

## 📃 Comments

```nova
-- Singe
// line comment

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
enum     typedef  struct
try      catch    except   throw
```

---

## 🔤 Literals

```nova
123         // integer
3.14        // float
"hello"     // string
'c'         // char
true, false // boolean
null        // null value
```

---

## 🧮 Operators

```nova
+   -   *   /   %         // arithmetic
==  !=  <   >   <=  >=    // comparison
&&  ||  !                 // logical
&   |   ^   ~   <<  >>    // bitwise
=   +=  -=  *=  /=  ...   // assignment
```

---

## 🏗️ Functions

```nova
fn main() {
  print("Hello, " + name)
}
```

*curly braces are optional for single expressions for functions, too*

```nova
fn main()
  print("Hello, " + name)
```

natively supports multiple return values just likr arguments, too

```nova
fn int, int test(int x, int y)
  return x, y

int v, error = test(x, y)
```

---

## 🔁 Control Structures

### If/Else

```nova
if x > 0 {
  print("Positive")
} else {
  print("Negative or zero")
}
```

### For (one one way to loop)

```nova
for int i = 0; i < 10; ++i {
  print(i)
}
```

*for iterators and generators, too*

```nova
for string s = it.next() {
  print(i)
}
```

---

## 🧱 Data Structures

### Enum

```nova
enum Color {
  Red,
  Green,
  Blue,
}
```

### Array

Fixed-size arrays declare with `[N]` after the type, index with `[i]`.

```nova
int[10] xs;
xs[0] = 1;
int v = xs[i + 1];
```

Indexing chains for nested arrays and call results.

```nova
int v = grid[a][b];
int w = row()[0];
```

---

## 🧩 Match Expression

```nova
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

```nova
fn risky()
  throw "Something went wrong"
```

### Catching Exceptions

```nova
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

```nova
import math

fn int hypot(int a, int b) {
  return math.sqrt(a * a + b * b)
}
```

A `luarocks` package is no different -- install it, then `import` it. The
runner adds the user rock tree to Lua's search path, so no environment
setup is needed (run under the Lua version the rock was built for):

```nova
import cjson

fn str roundtrip() {
  return cjson.encode(cjson.decode("[10, 20, 30]"))
}
```

Under the hood `import` is Lua's `require`, the same mechanism the compiler
itself is assembled from. A minimal language earns its minimalism by not
rebuilding what the host already does well.
