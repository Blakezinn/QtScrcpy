@echo off
rem Copyright 2026 qtscrcpy-net contributors
rem Licensed under the Apache License, Version 2.0 (the "License");
rem you may not use this file except in compliance with the License.
rem You may obtain a copy at http://www.apache.org/licenses/LICENSE-2.0
rem Unless required by applicable law or agreed to in writing, software
rem distributed under the License is distributed on an "AS IS" BASIS,
rem WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
rem See the License for the specific language governing permissions and
rem limitations under the License.
setlocal
if not defined QSC_QT_ROOT set "QSC_QT_ROOT=F:\Qt\5.15.2\msvc2019_64"
if not defined QSC_VCVARSALL set "QSC_VCVARSALL=C:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvarsall.bat"
call "%QSC_VCVARSALL%" x64
if errorlevel 1 exit /b 1
set "PATH=%QSC_QT_ROOT%\bin;%PATH%"
cd /d "%~dp0..\.."
cmake -S . -B out/build -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo "-DCMAKE_PREFIX_PATH=%QSC_QT_ROOT%" -DQT_DESIRED_VERSION=5 -DQSC_DEPLOY_PATH=out/deploy
if errorlevel 1 exit /b 1
cmake --build out/build --parallel 8
if errorlevel 1 exit /b 1
rem Upstream overrides the deploy variable; stage without changing client CMake.
cmake -E make_directory out/deploy
cmake -E copy_directory output/x64/RelWithDebInfo out/deploy
if errorlevel 1 exit /b 1
cmake -E copy_directory config out/deploy/config
cmake -E copy_directory keymap out/deploy/keymap
"%QSC_QT_ROOT%\bin\windeployqt.exe" --release --no-translations --no-compiler-runtime out/deploy/QtScrcpy.exe
if errorlevel 1 exit /b 1
for %%f in (msvcp140.dll msvcp140_1.dll vcruntime140.dll vcruntime140_1.dll) do copy /y "%SystemRoot%\System32\%%f" out\deploy\ >nul
exit /b 0
