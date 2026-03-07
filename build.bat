@echo off
setlocal

REM === NanoClaw on OpenHarmony - Build & Deploy Script ===

set PROJECT_DIR=%~dp0
set NODE_EXE="C:\Program Files\Huawei\DevEco Studio\tools\node\node.exe"
set HVIGOR="C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js"
set HAP_PATH=entry\build\default\outputs\default\entry-default-signed.hap
set BUNDLE_NAME=com.example.openclaw_on_openharmony

cd /d %PROJECT_DIR%

if "%1"=="clean" goto clean
if "%1"=="build" goto build
if "%1"=="install" goto install
if "%1"=="run" goto run
if "%1"=="uninstall" goto uninstall
if "%1"=="all" goto all
if "%1"=="" goto all

echo Usage: build.bat [clean^|build^|install^|run^|uninstall^|all]
echo   clean     - Clean build output
echo   build     - Build HAP file
echo   install   - Install HAP to device
echo   run       - Launch app on device
echo   uninstall - Uninstall app from device
echo   all       - Build + Install + Run (default)
goto end

:clean
echo [1/1] Cleaning...
%NODE_EXE% %HVIGOR% clean --no-daemon --no-parallel
goto end

:build
echo [1/1] Building HAP...
%NODE_EXE% %HVIGOR% assembleHap --mode module -p product=default -p buildMode=debug --no-daemon --no-parallel --stacktrace
if %errorlevel% neq 0 (
    echo.
    echo *** BUILD FAILED ***
    exit /b 1
)
echo.
echo Build OK: %HAP_PATH%
goto end

:install
echo [1/1] Installing to device...
if not exist %HAP_PATH% (
    echo HAP file not found: %HAP_PATH%
    echo Run "build.bat build" first.
    exit /b 1
)
hdc install -r %HAP_PATH%
if %errorlevel% neq 0 (
    echo.
    echo *** INSTALL FAILED ***
    echo Make sure device is connected: hdc list targets
    exit /b 1
)
echo Install OK
goto end

:run
echo [1/1] Launching app...
hdc shell aa start -a EntryAbility -b %BUNDLE_NAME% -m entry
echo App launched
goto end

:uninstall
echo [1/1] Uninstalling...
hdc shell bm uninstall -n %BUNDLE_NAME%
echo Uninstalled
goto end

:all
echo === Build + Install + Run ===
echo.

echo [1/3] Building HAP...
%NODE_EXE% %HVIGOR% assembleHap --mode module -p product=default -p buildMode=debug --no-daemon --no-parallel --stacktrace
if %errorlevel% neq 0 (
    echo.
    echo *** BUILD FAILED ***
    exit /b 1
)
echo Build OK
echo.

echo [2/3] Installing to device...
hdc install -r %HAP_PATH%
if %errorlevel% neq 0 (
    echo.
    echo *** INSTALL FAILED ***
    exit /b 1
)
echo Install OK
echo.

echo [3/3] Launching app...
hdc shell aa start -a EntryAbility -b %BUNDLE_NAME% -m entry
echo.
echo === Done ===
goto end

:end
endlocal
