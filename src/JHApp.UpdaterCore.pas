unit JHApp.UpdaterCore;

/// 콘솔/GUI updater 가 공유하는 업데이트 절차(검증 -> 백업 -> 교체 -> 상태 확인 -> 실패 시 복구)

interface

type
  TUpdaterLog = reference to procedure(const Text: string);

/// 명령줄 인수(--pid, --package ...)로 업데이트를 수행한다.
/// 성공하면 True. 실패하면 이전 버전 복구를 시도한 뒤 False 와 사유를 돌려준다.
/// OnLog 는 호출한 스레드에서 실행된다(UI 라면 호출 측에서 스레드 전환).
function RunUpdater(const OnLog: TUpdaterLog; out ErrorMessage: string): Boolean;

implementation

uses
  Winapi.Windows,
  System.SysUtils,
  System.Classes,
  System.Generics.Collections,
  System.IOUtils,
  System.Types,
  System.Hash,
  System.Zip,
  System.Net.HttpClient;

const
  SERVER_EXE_NAME = 'OozyAttendanceServer.exe';

var
  GOnLog: TUpdaterLog;
  LogFileName: string;
  ShouldRecoverOriginal: Boolean;
  RecoveryTargetDirectory: string;
  RecoveryExecutable: string;
  RecoveryStartHttpServer: Boolean;
  RecoveryProcess: THandle;

procedure Log(const Text: string);
begin
  if Assigned(GOnLog) then
    try
      GOnLog(Text);
    except
      // 화면 표시 실패가 업데이트를 막아서는 안 된다.
    end;
  if LogFileName = '' then
    Exit;
  try
    TFile.AppendAllText(LogFileName,
      FormatDateTime('yyyy-mm-dd hh:nn:ss', Now) + '  ' + Text + sLineBreak,
      TEncoding.UTF8);
  except
    // Updating must not fail solely because logging is unavailable.
  end;
end;

function ArgumentValue(const Name: string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to ParamCount - 1 do
    if SameText(ParamStr(I), Name) then
      Exit(ParamStr(I + 1));
end;

function HasArgument(const Name: string): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 1 to ParamCount do
    if SameText(ParamStr(I), Name) then
      Exit(True);
end;

procedure WaitForProcess(ProcessID: Cardinal);
var
  ProcessHandle: THandle;
  WaitResult: Cardinal;
begin
  ProcessHandle := OpenProcess(SYNCHRONIZE, False, ProcessID);
  if ProcessHandle = 0 then
    Exit;
  try
    WaitResult := WaitForSingleObject(ProcessHandle, 120000);
    if WaitResult <> WAIT_OBJECT_0 then
      raise Exception.Create('서버 프로그램이 제한 시간 안에 종료되지 않았습니다.');
  finally
    CloseHandle(ProcessHandle);
  end;
end;

function Sha256File(const FileName: string): string;
begin
  Result := LowerCase(THashSHA2.GetHashStringFromFile(FileName,
    THashSHA2.TSHA2Version.SHA256));
end;

function ExpectedChecksum(const FileName: string): string;
var
  Text: string;
  I: Integer;
begin
  Text := Trim(TFile.ReadAllText(FileName, TEncoding.UTF8));
  Result := '';
  for I := 1 to Length(Text) do
    if CharInSet(Text[I], ['0'..'9', 'a'..'f', 'A'..'F']) then
      Result := Result + LowerCase(Text[I])
    else if Result <> '' then
      Break;
  if Length(Result) <> 64 then
    raise Exception.Create('SHA-256 파일 형식이 올바르지 않습니다.');
end;

function StartServer(const FileName, WorkingDirectory: string;
  StartHttpServer: Boolean; out ProcessHandle: THandle): Boolean;
var
  StartupInfo: TStartupInfo;
  ProcessInfo: TProcessInformation;
  CommandLine: string;
  CommandBuffer: array of Char;
begin
  CommandLine := '"' + FileName + '"';
  if StartHttpServer then
    CommandLine := CommandLine + ' --start-server';
  SetLength(CommandBuffer, Length(CommandLine) + 1);
  StrPCopy(PChar(CommandBuffer), CommandLine);
  FillChar(StartupInfo, SizeOf(StartupInfo), 0);
  StartupInfo.cb := SizeOf(StartupInfo);
  FillChar(ProcessInfo, SizeOf(ProcessInfo), 0);
  Result := CreateProcess(nil, PChar(CommandBuffer), nil, nil, False, 0, nil,
    PChar(WorkingDirectory), StartupInfo, ProcessInfo);
  if Result then
  begin
    CloseHandle(ProcessInfo.hThread);
    ProcessHandle := ProcessInfo.hProcess;
  end
  else
    ProcessHandle := 0;
end;

function WaitForHealth(const Url: string; ProcessHandle: THandle): Boolean;
var
  Client: THTTPClient;
  I: Integer;
  ExitCode: Cardinal;
begin
  Result := False;
  Client := THTTPClient.Create;
  try
    Client.ConnectionTimeout := 1000;
    Client.ResponseTimeout := 1500;
    for I := 1 to 30 do
    begin
      if GetExitCodeProcess(ProcessHandle, ExitCode) and
        (ExitCode <> STILL_ACTIVE) then
        Exit(False);
      try
        if Client.Get(Url).StatusCode = 200 then
          Exit(True);
      except
        // The server may still be starting.
      end;
      Sleep(1000);
    end;
  finally
    Client.Free;
  end;
end;

procedure PruneBackups(const BackupRoot: string; Keep: Integer);
var
  Dirs: TStringDynArray;
  I: Integer;
begin
  if not TDirectory.Exists(BackupRoot) then
    Exit;
  try
    Dirs := TDirectory.GetDirectories(BackupRoot);
    TArray.Sort<string>(Dirs); // 이름이 버전-yyyymmdd-hhnnss 이므로 오래된 것이 앞쪽
    for I := 0 to Length(Dirs) - 1 - Keep do
      TDirectory.Delete(Dirs[I], True);
  except
    // 백업 정리 실패는 업데이트 결과에 영향을 주지 않는다.
  end;
end;

function StillRunning(ProcessHandle: THandle): Boolean;
var
  ExitCode: Cardinal;
begin
  Result := GetExitCodeProcess(ProcessHandle, ExitCode) and
    (ExitCode = STILL_ACTIVE);
end;

procedure Run;
var
  ParentPID: Cardinal;
  PackageFile, ChecksumFile, TargetDirectory, DatabaseFile: string;
  RawTargetDirectory: string;
  RestartFile, Version, HealthUrl, StagingDirectory: string;
  NewServerFile, InstalledServerFile, BackupDirectory, BackupServerFile: string;
  BackupDatabaseFile: string;
  ExpectedHash, ActualHash: string;
  StartHttpServer: Boolean;
  NewProcess: THandle;
  Replaced: Boolean;
begin
  ParentPID := StrToIntDef(ArgumentValue('--pid'), 0);
  PackageFile := ArgumentValue('--package');
  ChecksumFile := ArgumentValue('--checksum');
  RawTargetDirectory := ArgumentValue('--target');
  TargetDirectory := IncludeTrailingPathDelimiter(RawTargetDirectory);
  DatabaseFile := ArgumentValue('--database');
  RestartFile := ArgumentValue('--restart');
  Version := ArgumentValue('--version');
  HealthUrl := ArgumentValue('--health-url');
  StartHttpServer := HasArgument('--start-server');
  if RestartFile = '' then
    RestartFile := SERVER_EXE_NAME;
  if (ParentPID = 0) or not FileExists(PackageFile) or
    not FileExists(ChecksumFile) or (RawTargetDirectory = '') or
    not TPath.IsPathRooted(RawTargetDirectory) or
    not TDirectory.Exists(RawTargetDirectory) or
    (StartHttpServer and (HealthUrl = '')) then
    raise Exception.Create('업데이트 실행 인수가 올바르지 않습니다.');

  TDirectory.CreateDirectory(TPath.Combine(TargetDirectory, 'updates'));
  LogFileName := TPath.Combine(TargetDirectory, 'updates\updater.log');
  Log('업데이트 시작: ' + Version);
  Log('서버 프로그램이 종료되기를 기다립니다...');
  WaitForProcess(ParentPID);
  RecoveryTargetDirectory := TargetDirectory;
  RecoveryExecutable := TPath.Combine(TargetDirectory, RestartFile);
  RecoveryStartHttpServer := StartHttpServer;
  ShouldRecoverOriginal := True;

  ExpectedHash := ExpectedChecksum(ChecksumFile);
  ActualHash := Sha256File(PackageFile);
  if not SameText(ExpectedHash, ActualHash) then
    raise Exception.Create('업데이트 ZIP의 SHA-256 검증에 실패했습니다.');
  Log('SHA-256 검증 완료');

  StagingDirectory := TPath.Combine(TargetDirectory,
    'updates\staging-' + IntToStr(GetCurrentProcessId));
  if TDirectory.Exists(StagingDirectory) then
    TDirectory.Delete(StagingDirectory, True);
  TDirectory.CreateDirectory(StagingDirectory);
  Log('업데이트 파일 압축을 해제합니다...');
  TZipFile.ExtractZipFile(PackageFile, StagingDirectory);
  NewServerFile := TPath.Combine(StagingDirectory, SERVER_EXE_NAME);
  if not FileExists(NewServerFile) then
    raise Exception.Create('업데이트 ZIP에 서버 실행 파일이 없습니다.');

  BackupDirectory := TPath.Combine(TargetDirectory,
    'backup\' + Version + '-' + FormatDateTime('yyyymmdd-hhnnss', Now));
  TDirectory.CreateDirectory(BackupDirectory);
  InstalledServerFile := TPath.Combine(TargetDirectory, RestartFile);
  BackupServerFile := TPath.Combine(BackupDirectory, RestartFile);
  if FileExists(InstalledServerFile) then
    TFile.Copy(InstalledServerFile, BackupServerFile, True);
  BackupDatabaseFile := '';
  if (DatabaseFile <> '') and FileExists(DatabaseFile) then
  begin
    BackupDatabaseFile :=
      TPath.Combine(BackupDirectory, ExtractFileName(DatabaseFile));
    TFile.Copy(DatabaseFile, BackupDatabaseFile, True);
  end;
  Log('기존 실행 파일과 DB 백업 완료: ' + BackupDirectory);

  NewProcess := 0;
  Replaced := False;
  try
    try
      TFile.Copy(NewServerFile, InstalledServerFile + '.new', True);
      if not MoveFileEx(PChar(InstalledServerFile + '.new'),
        PChar(InstalledServerFile), MOVEFILE_REPLACE_EXISTING or
        MOVEFILE_WRITE_THROUGH) then
        RaiseLastOSError;
      Replaced := True;
      Log('서버 실행 파일 교체 완료');

      if not StartServer(InstalledServerFile, TargetDirectory, StartHttpServer,
        NewProcess) then
        RaiseLastOSError;
      Log('새 버전을 시작했습니다. 상태를 확인합니다...');
      if StartHttpServer and not WaitForHealth(HealthUrl, NewProcess) then
        raise Exception.Create('새 버전의 /health 상태 확인이 실패했습니다.');
      if not StartHttpServer then
      begin
        Sleep(3000); // HTTP 검증이 없으면 최소한 즉시 종료하지 않는지만 확인
        if not StillRunning(NewProcess) then
          raise Exception.Create('새 버전이 시작 직후 종료되었습니다.');
      end;
      Log('업데이트 완료: ' + Version);
    except
      on E: Exception do
      begin
        if NewProcess <> 0 then
        begin
          TerminateProcess(NewProcess, 2);
          WaitForSingleObject(NewProcess, 10000);
          CloseHandle(NewProcess);
          NewProcess := 0;
        end;
        if Replaced and FileExists(BackupServerFile) then
        begin
          Log('업데이트 실패, 이전 EXE 복구 시작: ' + E.Message);
          TFile.Copy(BackupServerFile, InstalledServerFile, True);
          // 새 버전이 DB 스키마를 바꿨을 수 있으므로 DB도 함께 되돌린다.
          if (BackupDatabaseFile <> '') and FileExists(BackupDatabaseFile) then
          begin
            TFile.Copy(BackupDatabaseFile, DatabaseFile, True);
            DeleteFile(DatabaseFile + '-wal');
            DeleteFile(DatabaseFile + '-shm');
            Log('DB를 백업본으로 복구했습니다.');
          end;
          if not StartServer(InstalledServerFile, TargetDirectory,
            StartHttpServer, NewProcess) then
            Log('이전 EXE는 복구했지만 재시작하지 못했습니다.')
          else
            Log('이전 EXE로 복구하고 재시작했습니다.');
          ShouldRecoverOriginal := False;
        end;
        raise Exception.Create('업데이트를 적용하지 못해 이전 버전으로 복구했습니다: ' +
          E.Message);
      end;
    end;
    ShouldRecoverOriginal := False;
    PruneBackups(TPath.Combine(TargetDirectory, 'backup'), 5);
  finally
    DeleteFile(InstalledServerFile + '.new');
    if NewProcess <> 0 then
      CloseHandle(NewProcess);
    if TDirectory.Exists(StagingDirectory) then
      TDirectory.Delete(StagingDirectory, True);
  end;
end;

function RunUpdater(const OnLog: TUpdaterLog; out ErrorMessage: string): Boolean;
begin
  GOnLog := OnLog;
  ShouldRecoverOriginal := False;
  ErrorMessage := '';
  try
    Run;
    Result := True;
  except
    on E: Exception do
    begin
      Result := False;
      ErrorMessage := E.Message;
      Log('업데이트 실패: ' + E.ClassName + ': ' + E.Message);
      if ShouldRecoverOriginal and FileExists(RecoveryExecutable) then
      begin
        if StartServer(RecoveryExecutable, RecoveryTargetDirectory,
          RecoveryStartHttpServer, RecoveryProcess) then
        begin
          Log('업데이트 적용 전 오류로 기존 서버를 다시 시작했습니다.');
          CloseHandle(RecoveryProcess);
        end
        else
          Log('기존 서버 자동 재시작에도 실패했습니다.');
      end;
    end;
  end;
end;

end.
