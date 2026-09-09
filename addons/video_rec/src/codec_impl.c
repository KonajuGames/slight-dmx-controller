/* The minih264 encoder and minimp4 muxer implementations, in their own
   C translation unit so their macro soup (U, MIN, MAX, ...) never meets
   godot-cpp. Both are single-header, public domain (CC0). */
#if defined(_MSC_VER)
#define _CRT_SECURE_NO_WARNINGS 1
#endif

#define MINIH264_IMPLEMENTATION
#define MINIMP4_IMPLEMENTATION

#include "minih264e.h"
#include "minimp4.h"
