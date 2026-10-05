#version 330 compatibility
// Convention: entry files stay pure ASCII (comments included), UTF-8 without BOM, LF endings.
// Legacy OptiFine decodes entries with the JVM default charset (GBK on zh-CN Windows) while include
// files are ASCII, and LWJGL 2 truncates each char to its low 8 bits; non-ASCII comments can turn
// into newlines or quotes and break GLSL parsing. Chinese docs go in shared program/lib or AGENTS.md.

#define STAGE_FRAGMENT
#define END
#include "/program/gbuffers_color.glsl"
