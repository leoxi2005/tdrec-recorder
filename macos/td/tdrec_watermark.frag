// ─────────────────────────────────────────────────────────────────────────
//  tdrec_watermark.frag  —  GLSL TOP cho TouchDesigner
//
//  Nhúng số frame của TouchDesigner vào 32 pixel ở góc TRÊN-TRÁI của ảnh.
//  TDRec đọc con số này để biết chính xác frame nào bị thiếu, rồi chèn bù
//  cho đúng nhịp — nhờ đó video không bao giờ trôi khỏi nhạc.
//
//  TDRec sẽ XOÁ dải watermark này khỏi file xuất, nên bạn không thấy nó
//  trong bản record cuối cùng.
//
//  ── Cách gắn ───────────────────────────────────────────────────────────
//  1. Tạo một GLSL TOP, trỏ Pixel Shader vào file này.
//  2. Nối tín hiệu cuối cùng của bạn vào input 0 của GLSL TOP.
//  3. Tab Vectors, thêm 2 uniform:
//         uFrame   →  absTime.frame        (Value0, dạng expression)
//         uBlock   →  2                    (phải khớp "Block size" trong TDRec)
//  4. Nối output của GLSL TOP vào Syphon Spout Out TOP.
//
//  LƯU Ý: chỉ nối GLSL TOP này vào nhánh đi tới Syphon. Nhánh đi ra màn
//  hình/máy chiếu thì lấy thẳng tín hiệu gốc, khỏi qua watermark.
// ─────────────────────────────────────────────────────────────────────────

uniform float uFrame;   // absTime.frame
uniform float uBlock;   // kích thước 1 block, tính bằng pixel (mặc định 2)

out vec4 fragColor;

void main()
{
    vec4 col = texture(sTD2DInputs[0], vUV.st);

    // uTD2DInfos[0].res = (1/w, 1/h, w, h)
    vec2 res = uTD2DInfos[0].res.zw;
    vec2 px  = vUV.st * res;

    float bs = max(uBlock, 1.0);

    // vUV gốc ở góc DƯỚI-trái, nên "trên cùng" là y gần res.y
    float fromTop = res.y - px.y;

    if (fromTop < bs && px.x < bs * 40.0)
    {
        uint bit = uint(floor(px.x / bs));

        // bit  0..7  : chuỗi nhận dạng 0xB4 — giúp TDRec phân biệt watermark
        //              thật với vùng ảnh đen/trắng phẳng (nếu không có chuỗi
        //              này, vùng đen tuyền sẽ bị đọc nhầm thành frame 0).
        // bit  8..31 : số frame
        // bit 32..39 : checksum
        uint counter = uint(uFrame) & 0xFFFFFFu;
        uint cksum   = (counter ^ (counter >> 8) ^ (counter >> 16)) & 0xFFu;

        float v;
        if (bit < 8u)       v = (((0xB4u    >> bit)        & 1u) != 0u) ? 1.0 : 0.0;
        else if (bit < 32u) v = (((counter  >> (bit - 8u)) & 1u) != 0u) ? 1.0 : 0.0;
        else                v = (((cksum    >> (bit - 32u))& 1u) != 0u) ? 1.0 : 0.0;

        // alpha = 1 để đảm bảo RGB đọc được kể cả khi ảnh có alpha = 0
        col = vec4(v, v, v, 1.0);
    }

    fragColor = TDOutputSwizzle(col);
}
