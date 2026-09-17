#ifndef NATIVE_REGISTER_TYPES_H
#define NATIVE_REGISTER_TYPES_H

#include <godot_cpp/core/class_db.hpp>

void initialize_native_module(godot::ModuleInitializationLevel p_level);
void uninitialize_native_module(godot::ModuleInitializationLevel p_level);

#endif // NATIVE_REGISTER_TYPES_H
