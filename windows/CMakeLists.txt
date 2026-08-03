cmake_minimum_required(VERSION 3.20)
project(tdrec VERSION 1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

if(MSVC)
    add_compile_options(/W3 /utf-8)
    # /utf-8 là bắt buộc: comment trong mã có tiếng Việt, thiếu cờ này MSVC
    # sẽ đọc sai và có thể báo lỗi cú pháp khó hiểu.

    # Nhúng thẳng CRT vào exe thay vì link động.
    #
    # Mặc định MSVC link động, exe sẽ cần VCRUNTIME140.dll + MSVCP140.dll từ
    # gói "Visual C++ Redistributable". Máy chưa cài gói đó thì Windows hiện
    # hộp thoại thiếu DLL — với người dùng nhìn giống hệt "app không mở được",
    # mà đây là công cụ đem sang máy show nên không thể đòi cài thêm gì.
    #
    # Phải đặt TRƯỚC mọi add_library/add_executable thì mới có tác dụng.
    # Biến này chỉ được đọc khi policy CMP0091 ở chế độ NEW — dòng
    # `cmake_minimum_required(VERSION 3.20)` phía trên đã bật sẵn, đừng hạ
    # số đó xuống dưới 3.15 kẻo cờ này lặng lẽ mất tác dụng.
    # Giá phải trả: exe to thêm khoảng 200 KB. Đổi lại là chép đi đâu cũng chạy.
    set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
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
        GIT_TAG        master
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
else()
    # Ngoài Windows vẫn build tdrec, chỉ thiếu lớp Spout. Chạy được
    # `--record --mock` để kiểm chứng toàn bộ vòng lặp ghi.
    add_executable(tdrec src/main.cpp)
    target_link_libraries(tdrec PRIVATE tdrec_core)
    message(STATUS "Khong phai Windows — tdrec chi ho tro --record --mock.")
endif()
