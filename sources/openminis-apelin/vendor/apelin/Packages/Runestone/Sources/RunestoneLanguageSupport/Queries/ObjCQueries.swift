// TreeSitterLanguages' C highlights followed by tree-sitter-objc's (which inherits C's), predicates and capture names adapted; README.md says how, kept as literals so
// the package ships no resource bundle for them.

extension RunestoneQueries {
    static let objcHighlights = ##"""
"break" @keyword
"case" @keyword
"const" @keyword
"continue" @keyword
"default" @keyword
"do" @keyword
"else" @keyword
"enum" @keyword
"extern" @keyword
"for" @keyword
"if" @keyword
"inline" @keyword
"return" @keyword
"sizeof" @keyword
"static" @keyword
"struct" @keyword
"switch" @keyword
"typedef" @keyword
"union" @keyword
"volatile" @keyword
"while" @keyword

"#define" @keyword
"#elif" @keyword
"#else" @keyword
"#endif" @keyword
"#if" @keyword
"#ifdef" @keyword
"#ifndef" @keyword
"#include" @keyword
(preproc_directive) @keyword

"--" @operator
"-" @operator
"-=" @operator
"->" @operator
"=" @operator
"!=" @operator
"*" @operator
"&" @operator
"&&" @operator
"+" @operator
"++" @operator
"+=" @operator
"<" @operator
"==" @operator
">" @operator
"||" @operator

"." @delimiter
";" @delimiter

(string_literal) @string
(system_lib_string) @string

(null) @constant
(number_literal) @number
(char_literal) @number

(call_expression
  function: (identifier) @function)
(call_expression
  function: (field_expression
    field: (field_identifier) @function))
(function_declarator
  declarator: (identifier) @function)
(preproc_function_def
  name: (identifier) @function.special)

(field_identifier) @property
(statement_identifier) @label
(type_identifier) @type
(primitive_type) @type
(sized_type_specifier) @type

((identifier) @constant
 (#match? @constant "^[A-Z][A-Z\\d_]*$"))

(identifier) @variable

(comment) @comment

; Objective-C

; Preprocs

(preproc_undef
  name: (_) @constant) @preproc

; Includes

(module_import "@import" @keyword.include path: (identifier) @namespace)

((preproc_include
  _ @keyword.include path: (_))
  (#match? @keyword.include "^#(include|import)$"))

; Type Qualifiers

[
  "@optional"
  "@required"
  "__covariant"
  "__contravariant"
  (visibility_specification)
] @keyword.modifier

; Storageclasses

[
  "@autoreleasepool"
  "@synthesize"
  "@dynamic"
  "volatile"
  (protocol_qualifier)
] @keyword.storage

; Keywords

[
  "@protocol"
  "@interface"
  "@implementation"
  "@compatibility_alias"
  "@property"
  "@selector"
  "@defs"
  "availability"
  "@end"
] @keyword

(class_declaration "@" @keyword "class" @keyword) ; I hate Obj-C for allowing "@ class" :)

(method_definition ["+" "-"] @keyword.function)
(method_declaration ["+" "-"] @keyword.function)

[
  "__typeof__"
  "__typeof"
  "typeof"
  "in"
] @keyword.operator

[
  "@synchronized"
  "oneway"
] @keyword.coroutine

; Exceptions

[
  "@try"
  "__try"
  "@catch"
  "__catch"
  "@finally"
  "__finally"
  "@throw"
] @keyword.exception

; Variables

((identifier) @variable.builtin
  (#match? @variable.builtin "^(self|super)$"))

; Functions & Methods

[
  "objc_bridge_related"
  "@available"
  "__builtin_available"
  "va_arg"
  "asm"
] @function.builtin

(method_definition (identifier) @function.method)

(method_declaration (identifier) @function.method)

(method_identifier (identifier)? @function.method ":" @function.method (identifier)? @function.method)

(message_expression method: (identifier) @function.method.call)

; Constructors

((message_expression method: (identifier) @constructor)
  (#eq? @constructor "init"))

; Attributes

(availability_attribute_specifier 
  [
    "CF_FORMAT_FUNCTION" "NS_AVAILABLE" "__IOS_AVAILABLE" "NS_AVAILABLE_IOS"
    "API_AVAILABLE" "API_UNAVAILABLE" "API_DEPRECATED" "NS_ENUM_AVAILABLE_IOS"
    "NS_DEPRECATED_IOS" "NS_ENUM_DEPRECATED_IOS" "NS_FORMAT_FUNCTION" "DEPRECATED_MSG_ATTRIBUTE"
    "__deprecated_msg" "__deprecated_enum_msg" "NS_SWIFT_NAME" "NS_SWIFT_UNAVAILABLE"
    "NS_EXTENSION_UNAVAILABLE_IOS" "NS_CLASS_AVAILABLE_IOS" "NS_CLASS_DEPRECATED_IOS" "__OSX_AVAILABLE_STARTING"
    "NS_ROOT_CLASS" "NS_UNAVAILABLE" "NS_REQUIRES_NIL_TERMINATION" "CF_RETURNS_RETAINED"
    "CF_RETURNS_NOT_RETAINED" "DEPRECATED_ATTRIBUTE" "UI_APPEARANCE_SELECTOR" "UNAVAILABLE_ATTRIBUTE"
  ]) @attribute

; Macros

(type_qualifier
  [
    "_Complex"
    "_Nonnull"
    "_Nullable"
    "_Nullable_result"
    "_Null_unspecified"
    "__autoreleasing"
    "__block"
    "__bridge"
    "__bridge_retained"
    "__bridge_transfer"
    "__complex"
    "__kindof"
    "__nonnull"
    "__nullable"
    "__ptrauth_objc_class_ro"
    "__ptrauth_objc_isa_pointer"
    "__ptrauth_objc_super_pointer"
    "__strong"
    "__thread"
    "__unsafe_unretained"
    "__unused"
    "__weak"
  ]) @function.macro.builtin

[ "__real" "__imag" ] @function.macro.builtin

((call_expression function: (identifier) @function.macro)
  (#eq? @function.macro "testassert"))

; Types

(class_declaration (identifier) @type)

(class_interface "@interface" . (identifier) @type superclass: _? @type category: _? @namespace)

(class_implementation "@implementation" . (identifier) @type superclass: _? @type category: _? @namespace)

(protocol_forward_declaration (identifier) @type) ; @interface :(

(protocol_reference_list (identifier) @type) ; ^

[
  "BOOL"
  "IMP"
  "SEL"
  "Class"
  "id"
] @type.builtin

; Constants

(property_attribute (identifier) @constant "="?)

[ "__asm" "__asm__" ] @constant.macro

; Properties

(property_implementation "@synthesize" (identifier) @property)

; Parameters

(method_parameter ":" @function.method (identifier) @variable.parameter)

(method_parameter declarator: (identifier) @variable.parameter)

(parameter_declaration 
  declarator: (function_declarator 
                declarator: (parenthesized_declarator 
                              (block_pointer_declarator 
                                declarator: (identifier) @variable.parameter))))

"..." @variable.parameter.builtin

; Operators

[
  "^"
] @operator

; Literals

(platform) @string.special

(version_number) @number

; Punctuation

"@" @punctuation.special

[ "<" ">" ] @punctuation.bracket
"""##
}
