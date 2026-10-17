package main

/*
#cgo LDFLAGS: -framework Carbon -framework CoreFoundation
#include <Carbon/Carbon.h>

// keyChar: the character the current keyboard layout types for a key code with these modifiers (Carbon
// modifier bits shifted right by 8, as UCKeyTranslate wants them), 0 when none or dead.
static UniChar keyChar(UInt16 code, UInt32 mods) {
	TISInputSourceRef src = TISCopyCurrentKeyboardLayoutInputSource();
	if (!src) return 0;
	CFDataRef data = (CFDataRef)TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData);
	if (!data) { CFRelease(src); return 0; }
	const UCKeyboardLayout *lay = (const UCKeyboardLayout *)CFDataGetBytePtr(data);
	UInt32 dead = 0; UniCharCount len = 0; UniChar buf[4];
	OSStatus st = UCKeyTranslate(lay, code, kUCKeyActionDown, mods, LMGetKbdType(),
		kUCKeyTranslateNoDeadKeysBit, &dead, 4, &len, buf);
	CFRelease(src);
	if (st != noErr || len != 1) return 0;
	return buf[0];
}
*/
import "C"

import "unicode"

// optionLayer maps what Terminal sends for an Option chord when "Use Option as Meta key" is on (ESC + the key's
// plain or shifted character) back to the character the owner's layout types with Option, e.g. on ABC-QWERTZ
// l -> @, 5 -> [, 7 -> |, and with shift 7 -> \. Read from the active layout at start.
func optionLayer() map[rune]rune {
	const shift, option = 0x02, 0x08 // shiftKey >> 8, optionKey >> 8
	m := map[rune]rune{}
	for code := 0; code < 128; code++ {
		for _, sh := range []uint32{0, shift} {
			base := rune(C.keyChar(C.UInt16(code), C.UInt32(sh)))
			opt := rune(C.keyChar(C.UInt16(code), C.UInt32(sh|option)))
			if base == 0 || opt == 0 || base == opt || !unicode.IsPrint(opt) || unicode.IsControl(base) {
				continue
			}
			if _, seen := m[base]; !seen {
				m[base] = opt
			}
		}
	}
	return m
}
