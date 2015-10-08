// Expecting definitions for the functions except printf.
// printf should be generated as a skipped function.
// A class with pure virtual member functions for each C function.

int foo (int a);
void bar (int a, int b);
void fooBar (void);
int printff (char*, ...);

extern int a (int out);

typedef int (*d_func) (int, int);
typedef struct Something_Big {
    int tiny;
} Something_Big;
extern void fun(d_func p, Something_Big b);
