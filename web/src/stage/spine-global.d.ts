// spine-webgl 3.8 以经典 <script> 挂在全局（web/public/lib/spine/spine-webgl.js，官方构建原样拷贝），
// 没有官方 d.ts；这里只声明成 any，用到的少数 API 在 engine.ts / loader.ts 里自己收窄。
declare const spine: any
