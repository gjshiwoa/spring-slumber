// 空 gbuffer: 丢弃全部几何，用于禁用某个渲染阶段
// 入口文件把 #include 指到本文件即可让该阶段完全不渲染

// ================================ FRAGMENT ================================
#ifdef STAGE_FRAGMENT

/* DRAWBUFFERS:0 */

void main() {
    discard;
}

#endif

// ================================= VERTEX =================================
#ifdef STAGE_VERTEX

void main() {
    gl_Position = vec4(2.0, 2.0, 2.0, 1.0); // 移出裁剪空间，光栅化前整体裁掉
}

#endif
