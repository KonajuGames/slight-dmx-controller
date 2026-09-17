// One GDExtension bundling every optional native feature: USB DMX output
// (usb_dmx/), MP4 video recording (video_rec/), fast song analysis
// (song_dsp/), and native MIDI feedback output (midi_out/). Combined so the
// exported package only ships one shared library, instead of one per
// feature — see addons/native/BUILD.md.

#include "register_types.h"

#include "usb_dmx/usb_dmx_output.h"
#include "video_rec/video_recorder.h"
#include "song_dsp/song_features.h"
#include "midi_out/midi_output.h"

#include <gdextension_interface.h>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

using namespace godot;

void initialize_native_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
	GDREGISTER_CLASS(UsbDmxOutput);
	GDREGISTER_CLASS(VideoRecorder);
	GDREGISTER_CLASS(SongFeatures);
	GDREGISTER_CLASS(MidiOutput);
}

void uninitialize_native_module(ModuleInitializationLevel p_level) {
	(void)p_level;
}

extern "C" {
GDExtensionBool GDE_EXPORT native_library_init(
		GDExtensionInterfaceGetProcAddress p_get_proc_address,
		GDExtensionClassLibraryPtr p_library,
		GDExtensionInitialization *r_initialization) {
	godot::GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);

	init_obj.register_initializer(initialize_native_module);
	init_obj.register_terminator(uninitialize_native_module);
	init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);

	return init_obj.init();
}
}
