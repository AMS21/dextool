// Prefixed with expect_ is expected to be found represented in the Symbol
// Container.
#ifndef VARIABLES_H
#define VARIABLES_H

// Test of primitive types
// must wrap to avoid multiple definition when including in main
#ifndef TEST_INCLUDE
int expect_primitive;
int expect_primitive_array[3];
#endif

const int expect_const_primitive_array[3] = {0, 1, 2};
extern int expect_b;

/* a duplicate, expecting it to be ignored */
extern int expect_b;

// Test of constness
extern const int expect_c;

// Test of primitive pointers
extern int* expect_d;
extern int** expect_e;

// Test of pointer constness
extern const int* expect_f;
extern int* const expect_g;
extern const int* const expect_h;
extern const int* const* expect_i;

// Test of typedef primitive type
typedef int my_int;
extern my_int expect_my_int;
extern const my_int expect_const_my_int;
extern const my_int* const expect_const_ptr_my_int;

// expect static storage
#endif // VARIABLES_H
