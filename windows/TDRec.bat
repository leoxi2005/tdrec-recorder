@echo off
REM ---------------------------------------------------------------------
REM TDRec.bat -- lop vo bam dup duoc cho tdrec.exe
REM
REM tdrec.exe la cong cu DONG LENH. Bam dup thang vao no thi Windows mo
REM console, chay xong lenh (khong co tham so = in bang huong dan) roi DONG
REM CUA SO NGAY -- nhin y het nhu "bam khong len". File .bat nay giu cua so
REM lai va hoi nguoi dung muon lam gi.
REM
REM Viet KHONG DAU co chu y: cmd.exe mac dinh dung codepage 437/1258, file
REM .bat co dau tieng Viet se hien ra ky tu rac. main.cpp cung in khong dau
REM vi cung ly do.
REM ---------------------------------------------------------------------

setlocal
title TDRec
color 07

REM Bam dup tu Explorer thi thu muc lam viec thuong dung, nhung "Run as
REM administrator" lai dat no thanh C:\Windows\System32. %~dp0 la thu muc
REM chua chinh file .bat nay -- luon dung.
cd /d "%~dp0"

if not exist "tdrec.exe" goto :khongthayexe

:menu
cls
echo.
echo   =====================================================
echo     T D R e c   --  ghi Spout ra video, khong rot frame
echo   =====================================================
echo.
echo     Thu muc: %CD%
echo.
echo     [1]  Liet ke Spout sender dang phat
echo     [2]  Kiem tra duong Spout  (probe)   ^<-- LAM CAI NAY TRUOC
echo     [3]  Bat dau ghi
echo     [4]  Tu kiem tra phan loi  (43 phep thu, khong can TouchDesigner)
echo     [5]  Xem bang huong dan day du
echo.
echo     [0]  Thoat
echo.
set "chon="
set /p "chon=  Chon roi bam Enter: "
if "%chon%"=="1" goto :senders
if "%chon%"=="2" goto :probe
if "%chon%"=="3" goto :record
if "%chon%"=="4" goto :selftest
if "%chon%"=="5" goto :help
if "%chon%"=="0" goto :ket
goto :menu

REM ---------------------------------------------------------------------
:senders
cls
echo.
echo   -- Spout sender dang phat ---------------------------
echo.
tdrec.exe --senders
echo.
echo   Khong thay ten nao? Trong TouchDesigner kiem tra:
echo     - Syphon Spout Out TOP da bat Active chua
echo     - TOP do co dang COOK khong (khong cook = lang le ngung phat)
goto :xong

REM ---------------------------------------------------------------------
:probe
cls
echo.
echo   -- Kiem tra duong Spout -----------------------------
echo.
echo   Nhan frame trong 5 giay roi bao cao. KHONG dung ffmpeg,
echo   khong ghi file -- chi de xac nhan TD co dang phat khong.
echo.
tdrec.exe --senders
echo.
set "sender="
set /p "sender=  Ten sender (bo trong = sender dang active): "
echo.
if "%sender%"=="" (
    tdrec.exe --probe
) else (
    tdrec.exe --probe --sender "%sender%"
)
echo.
echo   Mau bi sai do/xanh?  chay lai voi  --swap-rb
echo   Anh bi lon nguoc?    chay lai voi  --flip
goto :xong

REM ---------------------------------------------------------------------
:record
cls
echo.
echo   -- Bat dau ghi --------------------------------------
echo.

where ffmpeg >nul 2>nul
if errorlevel 1 (
    echo   !! KHONG THAY ffmpeg trong PATH.
    echo.
    echo   TDRec goi ffmpeg de encode, goi cai dat nay khong kem san no.
    echo   Cai bang mot trong hai cach:
    echo       winget install Gyan.FFmpeg
    echo       choco install ffmpeg
    echo   Roi MO LAI cua so nay ^(PATH chi cap nhat o phien moi^).
    goto :xong
)

tdrec.exe --senders
echo.
set "sender="
set /p "sender=  Ten sender (bo trong = sender dang active): "
set "fps="
set /p "fps=  Nhip ghi fps [mac dinh 60]: "
if "%fps%"=="" set "fps=60"
set "out="
set /p "out=  Luu ra file [mac dinh tdrec_out.mov]: "
if "%out%"=="" set "out=tdrec_out.mov"

echo.
echo   Codec:
echo     [1] hevc_nvenc  -- NVIDIA, nhe may nhat        (mac dinh)
echo     [2] h264_nvenc  -- NVIDIA, tuong thich rong hon
echo     [3] libx264     -- khong can NVIDIA, an CPU
set "cd_chon="
set /p "cd_chon=  Chon [1]: "
if "%cd_chon%"=="2" (set "codec=h264_nvenc") else if "%cd_chon%"=="3" (set "codec=libx264") else (set "codec=hevc_nvenc")

echo.
echo   ----------------------------------------------------
echo     sender : %sender%
echo     fps    : %fps%
echo     codec  : %codec%
echo     file   : %out%
echo   ----------------------------------------------------
echo.
echo   Dang ghi. Nhan Ctrl+C mot lan de DUNG va dong file tu te.
echo   ^(Dong thang cua so se lam hong file.^)
echo.
pause
echo.
if "%sender%"=="" (
    tdrec.exe --record --fps %fps% --codec %codec% --out "%out%"
) else (
    tdrec.exe --record --sender "%sender%" --fps %fps% --codec %codec% --out "%out%"
)
goto :xong

REM ---------------------------------------------------------------------
:selftest
cls
echo.
echo   -- Tu kiem tra phan loi -----------------------------
echo.
if not exist "tdrec_core_test.exe" (
    echo   Khong thay tdrec_core_test.exe canh file nay.
    goto :xong
)
tdrec_core_test.exe
echo.
echo   Tat ca dat = phan tinh toan chay dung, moi loi con lai
echo   nam o lop Spout hoac o ffmpeg.
goto :xong

REM ---------------------------------------------------------------------
:help
cls
echo.
tdrec.exe --help
goto :xong

REM ---------------------------------------------------------------------
:khongthayexe
cls
echo.
echo   !! Khong thay tdrec.exe trong thu muc:
echo      %CD%
echo.
echo   Nguyen nhan hay gap nhat: dang bam dup file .bat NGAY BEN TRONG
echo   file .zip. Windows chi giai nen tam moi minh file .bat ra nen no
echo   khong thay tdrec.exe dau ca.
echo.
echo   Cach sua:
echo     1. Chuot phai file TDRec-Windows.zip  -^>  Properties
echo        -^>  tick o "Unblock"  -^>  OK
echo        ^(buoc nay go bo canh bao SmartScreen cho file tai tu mang^)
echo     2. Chuot phai  -^>  "Extract All..."  ra mot thu muc that
echo     3. Vao thu muc vua giai nen, bam dup TDRec.bat
echo.
goto :xong

REM ---------------------------------------------------------------------
:xong
echo.
echo   -----------------------------------------------------
pause
goto :menu

:ket
endlocal
