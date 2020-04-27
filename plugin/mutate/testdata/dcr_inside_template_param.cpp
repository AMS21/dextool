#include <type_traits>

namespace testing {

struct Test {};

} // namespace testing

template <typename T>
//  Note that SuiteApiResolver inherits from T because
//  SetUpTestSuite()/TearDownTestSuite() could be protected. Ths way
//  SuiteApiResolver can access them.
struct SuiteApiResolver : T {
    // testing::Test is only forward declared at this point. So we make it a
    // dependend class for the compiler to be OK with it.
    using Test = typename std::conditional<sizeof(T) != 0, ::testing::Test, void>::type;
};

int main(int argc, char** argv) {
    int x = 2 + argc;
    if (x == 1)
        return 2;
    return 0;
}
