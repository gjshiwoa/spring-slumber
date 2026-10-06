// 初始化 pass: deferred_init（deferred1 阶段——deferred 槽为云形状场生成 pass，见
// program/deferred_cloud_field.glsl：同帧先行、本 pass 探针同帧消费零滞后；vsh = 通用全屏 vsh，
// 本 program 无自定义 vsh 段，fsh 按需声明同名 in）。位于不透明 gbuffers 之后、半透明之前，
// 初始化场景颜色 colortex6：
// 位置重建统一去抖基底——`像素 uv − vJitter`（TAAU 再 /S）一次算出，天空视线（z = 1 远平面）与
// 几何 viewPos（z = depthtex1 原始深度）共用同一组 xy（几何 vsh 抖动 +J 后本像素含「位置 −J」处
// 场景，去抖重建得到真实位置）；几何信息采样全 texelFetch(gl_FragCoord) 精确纹素、无 vTexCoord。
// 天空与深度缓冲几何在地平线边界像素内衔接一致、阴影贴图采样位置逐帧对齐，composite_taa 时间
// 累积平滑 LUT 双线性 facets 与地平线边界
// 天空像素（depthtex1 >= 1——纯不透明深度，depthtex0 此刻可能已混入粒子深度）采样 colortex7
// sky-view LUT，叠加太阳盘 / 月亮盘 / 星盘（解析绘制——世界方向一次归一、LUT / 盘 / 云全链共享，
// 见 main 天空分支）与 2D 平面云（lib/atmosphere/clouds.glsl：LUT 是纯方向函数、云有平移视差
// 故不进 LUT；云的伪自阴影探针读 colortex1 云形状场——deferred 槽同帧生成（滞后仅 LUT 一帧），
// 机制见 clouds.glsl；预乘合成 cloud.rgb + 天空 × cloud.a）；天空在本 pass 进 colortex6 是时序
// 关键——之后前向半透明（硬件混合直写叠加）才有正确天空背景（含云），画在 composite（半透明
// 之后）则水面叠天空处混到黑底
// colortex6 自此全程线性（final 的 linearToSrgb 是唯一离开线性空间的位置）
// 几何像素：解包 colortex4/5（albedo / labPBR 高光贴图〔colortex4.ba〕/ 八面体法线 / lmcoord 重映射）
// + 去抖 uv 重建 viewPos 后经
// shadeSurface 着色（直接光 = 阴影可见性 × 直射透射率 × 辐照度 × wrap 余弦 + 直射 GGX 高光 +
// 环境 / 方块光，
// 见 lib/lighting/lighting.glsl；albedo a 通道植被标记经 materialSSSStrength 转为 SSS 强度）
// 主颜色在 colortex6（= gaux3）：前向半透明 after 路径以主颜色为合成目标。**前向半透明（water /
// hand_water / weather / textured 族 / 实体）一律输出 (色, alpha) 交 ROP 硬件 alpha 混合直写
// 叠加于本 pass 输出之上**（时机两可族经 per-buffer 行、water 族经引擎默认半透明混合；2026-10
// 兼容性标准化：gaux3 手动合成全面废止——读正在写的附件在个别驱动未定义 + 同 draw 重叠竞态）；
// **water 水面框架的
// 折射 / SSR 是位移采样**——落点会踩进同一 draw 的其他水像素，读活缓冲 = 读到「未写 = deferred 背景」
// 与「已写 = 合成水色」的光栅序竞态（实机 = 水面暗色裂缝 / 闪变带，2026-10 修），故本 pass 另写
// **colortex4 背景快照**（DRAWBUFFERS:467）：编码 = 场景色 × 曝光 ÷ WATER_BG_SNAPSHOT_HEADROOM 的
// 曝光归一化存储——RGBA16 [0,1] 域装下 HDR（旧「colortex4 场景副本」方案被删的根因即裸存被截断，
// 编码后复活；water 独占读者、无旧方案的逐层回写开销），water 经 gaux1 采样解码。gbuffer 数据
//（colortex4/5）本 pass 解包消费完毕后即被快照覆盖（colortex4）/ 留存帧末无读者（colortex5）。
// 兼写 colortex7：pass 顺序标记槽写 1（本 pass 之后的 gbuffers〔water / hand_water / weather〕读到 1、
// 之前的〔textured 族〕读到 0，composite12 帧末复位），读取端 lib/common/pipeline/pass_order_marker.glsl；
// 其余 texel 同位置读回透传、逐位保值

#define FULLSCREEN_DIRECT_TRANSMITTANCE

#include "/lib/common/globals/constants.glsl"
#include "/lib/common/utils/color.glsl"
#include "/lib/common/globals/uniforms.glsl"
#include "/lib/common/utils/packing.glsl"
#include "/lib/common/pipeline/gbuffer_data.glsl"
#include "/lib/common/utils/space.glsl"
#include "/lib/common/utils/noise.glsl"
#include "/lib/common/utils/filters.glsl"
#include "/lib/post/bloom.glsl"
#include "/lib/post/exposure.glsl"
#include "/lib/atmosphere/atmosphere.glsl"
#ifdef CLOUDS_2D
#define FULLSCREEN_CLOUD_TRANSMITTANCE // 云高处透射率 varying（CLOUDS_2D 在 constants.glsl——宏门控须在其后；atmosphere.glsl 已于上方引入）
#endif
#include "/lib/lighting/ambient.glsl"
#include "/program/fullscreen_vsh.glsl"
#include "/lib/atmosphere/sky.glsl"
#include "/lib/atmosphere/clouds.glsl"
#include "/lib/lighting/shadow.glsl"
#ifdef STAGE_FRAGMENT
// 通用全屏 vsh 输出的帧数据——按需 in 声明；须位于 lighting.glsl 之前（shadeSurface 直接引用
// 同名全局），getSkyColorWorld 的方向 / 地平线 / LUT 有效性经参数传入
in vec2 vJitter;
in vec3 vSunDirection;
in vec3 vMoonDirection;
in vec3 vLightDirection;
in vec3 vDirectIrradiance;
in vec3 vDirectTransmittance;
#ifdef CLOUDS_2D
in vec3 vCloudTransmittance;
#endif
in vec3 vSkyAmbient;
in vec3 vHorizon;
in float vExposure; // 背景快照编码用（槽位无效回退 1.0——与 water 解码端同帧读同一槽位、成对一致）
flat in float vSkyLutValid; // 0/1（flat float——bool varying 不为补丁器 / 部分驱动所容）
#endif
#include "/lib/lighting/lighting.glsl"

// ================================ FRAGMENT ================================
#ifdef STAGE_FRAGMENT

/* DRAWBUFFERS:467 */

layout(location = 0) out vec4 outBgSnapshot; // colortex4：背景快照（曝光归一化编码，water 折射 / SSR 位移采样读——机制见文件头）
layout(location = 1) out vec4 outColor; // colortex6：场景颜色（前向半透明经硬件 alpha 混合直写叠加于其上——gbuffers 阶段无读者）
layout(location = 2) out vec4 outMisc;  // colortex7：pass 顺序标记写 1 + 其余 texel 透传

void main() {
    // 几何信息（depthtex1 / colortex4/5）texelFetch 精确纹素读取——不插值、无 vTexCoord
    //（全屏 pass 逐像素与缓冲一一对应，与 composite_taa 的锚点采样同款纪律）
    ivec2 pixel = ivec2(gl_FragCoord.xy);
    float depth = texelFetch(depthtex1, pixel, 0).r;

    // 统一去抖 uv：gl_FragCoord 像素中心 uv − 当前帧 jitter（与几何抖动同相位），天空视线与几何
    // viewPos 共用的位置重建基底。TAAU：本 pass quad 已缩进左下 [0,S]² 子区域，gl_FragCoord/视口
    // ∈ [0,S]——除 S 归一回视场全域、jitter 随域同步 /S（一步合成，公式单真源 =
    // noise.glsl 的 applyInverseJitter 参数版——vJitter varying 传入免每像素 Halton 表重算）
    vec2 uv = applyInverseJitter(gl_FragCoord.xy / vec2(viewWidth, viewHeight), vJitter);

    vec3 color;
    if (depth >= 1.0) {
#ifdef DIM_NO_ATMOSPHERE
        // 维度极简档（下界 / 末地，2026-10 接入）：天空像素 = 常量维度天色（constants.glsl 的
        // DIMENSION_SKY_COLOR，waterSkyReflection 的 miss 回退同源）——sky-view LUT / 日月盘 /
        // 云全部分支编译剔除；colortex7 的 LUT 区域本维度不生成（composite12 维度门控）、无读者
        color = DIMENSION_SKY_COLOR;
#if defined(END) && defined(STARS)
        // 末地星空（2026-10）：主世界默认星盘单真源复用（getStars——夜门在函数内经 #ifdef END
        // 常开、planetHit 切割剔除 = 星图覆盖全球虚空）；星盘是方向函数、方向重建为本档独付
        //（下界纯常量零方向重建——封闭洞窟维度不接入），z = 1 远平面视线与大气档同款；星点随
        // 同帧背景快照进 water 折射背景
        vec3 skyDirView = screenToView(vec3(uv, 1.0));
        vec3 skyDirWorld = normalize(viewToWorldDirection(skyDirView));
        color += getStars(skyDirWorld, vSunDirection, vMoonDirection);
#endif
#else
        // 天空视线：z = 1 落在远平面；世界方向一次归一（2026-10 性能，天空分支世界方向单次化）：
        // LUT（getSkyColorWorld）/ 日月盘 / 星盘 / 云各 lib 世界系核心全链共享同一 skyDirWorld——
        // 旧链每函数各付一次 viewToWorldDirection + normalize（每天空像素 5 次）收敛为 1 次，
        // fog.glsl 雾色链 2026-09 优化同款纪律。LUT 为 composite12 上帧生成（滞后一帧无视觉差异），
        // 非活动半区由 getSkyColorWorld 门控跳过、有效性取 vsh 探针（无效即首帧 / 缓冲重建，回退
        // 轻量天空）
        vec3 skyDirView = screenToView(vec3(uv, 1.0));
        vec3 skyDirWorld = normalize(viewToWorldDirection(skyDirView));
        color = getSkyColorWorld(skyDirWorld, vSunDirection, vMoonDirection, vHorizon, vSkyLutValid > 0.5);
        // 太阳盘解析叠加（LUT 纹素角尺寸装不下 ~2° 圆盘）：与地面直射光同源的透射率红化、
        // planetHitDistance 地平线遮挡；画在云合成之前 = 云遮挡太阳，地形遮挡由 depth >= 1 天然给出
        color += getSunDiskWorld(skyDirWorld, vSunDirection);
#ifdef MOON_DISK
        // 月亮盘（getMoonDiskWorld，太阳盘同构同纪律）：白天月亮在地平线下、被遮挡判定整段早退
        color += getMoonDiskWorld(skyDirWorld, vMoonDirection);
#endif
#ifdef STARS
        // 星盘（getStars：立方体网格点星、星图与月固连、太阳高度夜门渐显）：画在云之前 = 云遮星，
        // 星星也进同帧背景快照（water 折射背景自动正确）
        color += getStars(skyDirWorld, vSunDirection, vMoonDirection);
#endif
#ifdef CLOUDS_2D
        // 2D 平面云叠加（标准 alpha 合成：cloud.rgb = 未预乘云色、cloud.a = 不透明度——云色暗时
        // 呈暗剪影而非透明，2026-10 修复）：地形像素不进本分支、遮挡天然正确；云不写深度，TAA 按天空
        // 路径处理（纯旋转链重投影），TAAU 档与天空同路径上采样
        vec4 cloud = getPlanarCloudsWorld(skyDirWorld, vLightDirection,
                                          vDirectIrradiance, vCloudTransmittance, vSkyAmbient);
        color = mix(color, cloud.rgb, cloud.a);
#endif
#endif // DIM_NO_ATMOSPHERE
    } else {
        // 几何光照：colortex4.rg 解包 albedo（sRGB 反 gamma；a 通道为标记位）、colortex4.ba 解包
        // labPBR 高光贴图（直射 GGX 高光消费，同 texel 零新增 fetch），colortex5.rg 八面体
        // 法线、.ba 原始 lmcoord 重映射；viewPos = 去抖 uv + 本像素原始深度
        vec4 gAlbedoSpec = texelFetch(colortex4, pixel, 0);
        vec4 gNormalLm = texelFetch(colortex5, pixel, 0);
        vec4 gAlbedo = unpack2x16To4x8(gAlbedoSpec.rg);
        vec3 albedo = srgbToLinear(gAlbedo.rgb);
        float sssStrength = materialSSSStrength(gAlbedo.a);
        vec3 normalView = decodeOctahedral(gNormalLm.rg);
        vec2 lm = remapLightmap(gNormalLm.ba);
        vec3 viewPos = screenToView(vec3(uv, depth));
        color = shadeSurface(albedo, normalView, lm, viewPos, vDirectTransmittance, sssStrength,
                             unpack2x16To4x8(gAlbedoSpec.ba));

        // ---- 调试：物品标记可视化（红 = 植被（block.properties 显式列表）、原色 = 未标记；
        // 块注释停用，恢复时去掉 /* 与 */ 两行）----
        /*
        if (sssStrength > 0.0) {
            color = vec3(1.0, 0.0, 0.0);
        }
        */
    }
    // pass 顺序标记（诊断，机制见 lib/common/pipeline/pass_order_marker.glsl）：标记槽写 1 =
    // 此刻起 gbuffers 读到「deferred 之后」；其余 texel 读回透传逐位保值（colortex7 除标记外
    // 内容不变；同 pass 读 + 写与 composite12 透传同款已知取舍）
    outMisc = pixel == PASS_ORDER_MARKER_TEXEL ? vec4(1.0) : texelFetch(colortex7, pixel, 0);

    // 背景快照（colortex4）：编码 = 场景色 × 曝光 ÷ HEADROOM 进 [0,1]（RGBA16），water 经 gaux1
    // 采样 × HEADROOM ÷ 曝光解码——两端同帧读同一曝光槽位（含无效回退 1.0 的同一分支），精确还原、
    // 仅超余量的极亮背景滚降（量级分析见 constants.glsl）。几何像素的 gbuffer 解包（上方 texelFetch）
    // 与本写入为同纹素先读后写——composite12 对 colortex7 的透传同款已知取舍；ping-pong 下采样见
    // 写入前面、写入翻到后面，water 随后读到的即快照
    outBgSnapshot = vec4(clamp(color * vExposure / WATER_BG_SNAPSHOT_HEADROOM, 0.0, 1.0), 1.0);
    outColor = vec4(color, 1.0);
}

#endif
