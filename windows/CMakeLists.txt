cmake_minimum_required(VERSION 3.20)
project(tdrec VERSION 1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

if(MSVC)
    add_compile_options(/W3 /utf-8)
    # /utf-8 là bắt buộc: comment trong mã có tiếng Việt, thiếu cờ này MSVC
    # sẽ đọc sai và có thể báo lỗi cú pháp khó hiểu.

    # ĐỪNG nhúng CRT vào exe bằng CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded".
    #
    # v1.0.1 đã thử và phải rút lại. Nhúng CRT làm exe phồng từ 92 KB lên
    # 349 KB và bảng import gần như trống (không còn gọi MSVCP140.dll). Với
    # bộ quét heuristic thì đó chính là chân dung của một packer: file nhỏ,
    # không chữ ký, import trống, lại sinh tiến trình con. Kết quả là
    # Defender chặn NGAY LÚC TẢI — người dùng không lấy nổi file zip về, còn
    # bản 92 KB link động thì tải bình thường.
    #
    # Cách giữ được "không phải cài gì" mà không đánh đổi: link động như cũ,
    # rồi chép mấy DLL runtime nằm cạnh exe (app-local deployment — Microsoft
    # cho phép phát hành kèm). Xem khối add_custom_command bên dưới.
else()
    add_compile_options(-Wall -Wextra -Wno-unused-parameter)
endif()

# ── Phần lõi: đa nền tảng, không phụ thuộc Spout/DirectX ─────────────────
add_library(tdrec_core STATIC
    src/core/watermark.cpp
    src/core/frame_pipeline.cpp
    src/core/ffmpeg_sink.cpp
    src/core/frame_source.cpp
)
target_include_directories(tdrec_core PUBLIC src)

# ── Bộ kiểm tra phần lõi: build và chạy được trên MỌI hệ điều hành ───────
# Chạy cái này trước tiên. Nếu nó đạt, mọi lỗi còn lại nằm ở lớp Spout.
add_executable(tdrec_core_test src/core_test.cpp)
target_link_libraries(tdrec_core_test PRIVATE tdrec_core)

enable_testing()
add_test(NAME core COMMAND tdrec_core_test)

# ── Bản Windows đầy đủ ───────────────────────────────────────────────────
if(WIN32)
    include(FetchContent)

    # Spout2 SDK. Nếu bản master đổi cấu trúc thư mục và build hỏng, ghim lại
    # một tag cụ thể ở đây (ví dụ GIT_TAG 2.007.015).
    # SOURCE_SUBDIR tro toi thu muc khong co CMakeLists -> CMake chi TAI VE
    # chu khong build project cua Spout. Ta chi can vai file .cpp cua ho; build
    # ca project se ton them nhieu phut va keo theo phu thuoc OpenGL khong dung toi.
    FetchContent_Declare(spout2
        GIT_REPOSITORY https://github.com/leadedge/Spout2.git
        # GHIM tag cu the, dung de "master". Keo master thi moi lan CI chay
        # lai ra mot ban khac nhau -> ma bam cua tdrec.exe khong on dinh, nguoi
        # dung khong the doi chieu de biet file minh tai co dung khong.
        GIT_TAG        2.007.017
        GIT_SHALLOW    TRUE
        SOURCE_SUBDIR  cmake-no-build
    )
    FetchContent_MakeAvailable(spout2)

    set(SPOUT_SDK "${spout2_SOURCE_DIR}/SPOUTSDK")
    set(SPOUT_GL  "${SPOUT_SDK}/SpoutGL")
    set(SPOUT_DX  "${SPOUT_SDK}/SpoutDirectX/SpoutDX")

    # Biên dịch thẳng các file nguồn cần dùng thay vì mượn target của Spout —
    # ít phụ thuộc vào cách họ cấu hình CMake, dễ đoán hơn khi có trục trặc.
    add_library(spoutdx STATIC
        "${SPOUT_DX}/SpoutDX.cpp"
        "${SPOUT_GL}/SpoutSenderNames.cpp"
        "${SPOUT_GL}/SpoutSharedMemory.cpp"
        "${SPOUT_GL}/SpoutUtils.cpp"
        "${SPOUT_GL}/SpoutFrameCount.cpp"
        "${SPOUT_GL}/SpoutDirectX.cpp"
        "${SPOUT_GL}/SpoutCopy.cpp"
    )
    target_include_directories(spoutdx PUBLIC "${SPOUT_DX}" "${SPOUT_GL}")

    # Cac thu vien duoi day deu bat buoc, phat hien bang cach bien dich cheo:
    #   winmm   -> timeBeginPeriod/timeEndPeriod trong SpoutFrameCount
    #   version -> GetFileVersionInfo trong SpoutUtils
    #   shlwapi, ole32 -> tien ich duong dan va COM
    target_link_libraries(spoutdx PUBLIC d3d11 dxgi winmm version shlwapi ole32)

    # KHONG dat WIN32_LEAN_AND_MEAN: no loai bo mmsystem.h, ma SpoutFrameCount
    # can timeBeginPeriod tu do -> loi 'TIMECAPS was not declared'.
    target_compile_definitions(spoutdx PUBLIC NOMINMAX)

    # SpoutCopy dung ham SSE3 (_mm_shuffle_epi8). MSVC bat san, GCC/Clang thi khong.
    if(NOT MSVC)
        target_compile_options(spoutdx PRIVATE -mssse3)
    endif()

    add_executable(tdrec
        src/main.cpp
        src/win/spout_source.cpp
    )
    target_link_libraries(tdrec PRIVATE tdrec_core spoutdx)
    target_compile_definitions(tdrec PRIVATE NOMINMAX)

    # Chép VCRUNTIME140.dll / VCRUNTIME140_1.dll / MSVCP140.dll nằm cạnh exe.
    # Windows tìm DLL ở thư mục chứa exe trước tiên, nên máy chưa cài VC++
    # Redistributable vẫn chạy được — mà exe thì vẫn link động, giữ đúng hình
    # dạng mà bộ quét virus coi là bình thường.
    #
    # SKIP=TRUE để module chỉ DÒ ra đường dẫn chứ không tự sinh luật install.
    set(CMAKE_INSTALL_SYSTEM_RUNTIME_LIBS_SKIP TRUE)
    include(InstallRequiredSystemLibraries)

    if(CMAKE_INSTALL_SYSTEM_RUNTIME_LIBS)
        foreach(dll ${CMAKE_INSTALL_SYSTEM_RUNTIME_LIBS})
            add_custom_command(TARGET tdrec POST_BUILD
                COMMAND ${CMAKE_COMMAND} -E copy_if_different
                        "${dll}" "$<TARGET_FILE_DIR:tdrec>"
                COMMENT "Chep runtime DLL canh tdrec.exe: ${dll}")
        endforeach()
    else()
        message(WARNING
            "Khong do duoc runtime DLL cua MSVC. tdrec.exe se doi may dich "
            "da cai VC++ Redistributable.")
    endif()
else()
    # Ngoài Windows vẫn build tdrec, chỉ thiếu lớp Spout. Chạy được
    # `--record --mock` để kiểm chứng toàn bộ vòng lặp ghi.
    add_executable(tdrec src/main.cpp)
    target_link_libraries(tdrec PRIVATE tdrec_core)
    message(STATUS "Khong phai Windows — tdrec chi ho tro --record --mock.")
endif()
