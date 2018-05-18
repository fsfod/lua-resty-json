#ifndef UTIL_H
#define UTIL_H

#ifdef DEBUG
#include <stdlib.h> /* for abort */
#endif

#include "ljson_parser.h"

#ifndef _MSC_VER
#define offsetof(t, m)  __builtin_offsetof(t, m)
#define likely(x)   __builtin_expect((x),1)
#define unlikely(x) __builtin_expect((x),0)
#else
#define likely(x) (x)
#define unlikely(x) (x)
#define strncasecmp _tcsnicmp 
#endif

#ifdef DEBUG
    #define ASSERT(c) if (!(c))\
        { fprintf(stderr, "%s:%d Assert: %s\n", __FILE__, __LINE__, #c); abort(); }
#else
    #define ASSERT(c) ((void)0)
#endif

#endif
