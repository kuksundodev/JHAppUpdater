unit JHApp.UpdaterCore;

/// 콘솔/GUI updater 가 공유하는 업데이트 절차
///   검증 -> 파일 목록 작성 -> 백업 -> 교체(EXE/DLL/설정) -> 상태 확인 -> 실패 시 복구
///
/// 명령줄 인수
///   --pid <n>             종료를 기다릴 서버 PID                      (필수)
///   --package <zip>       업데이트 ZIP                                 (필수)
///   --checksum <file>     SHA-256 파일                                 (필수)
///   --target <dir>        설치 폴더, 절대 경로                         (필수)
///   --exe <name>          ZIP 루트의 서버 실행 파일 이름 (기본 OozyAttendanceServer.exe)
///   --restart <name>      설치 폴더에서 교체/재시작할 실행 파일 이름 (기본 --exe 값)
///   --database <file>     백업/복구할 SQLite DB (상대 경로면 --target 기준)
///   --version <text>      로그/백업 폴더 이름용 버전
///   --start-server        서버를 --start-server 인수로 시작
///   --health-url <url>    --start-server 사용 시 필수
///   --keep-backups <n>    보관할 백업 개수 (기본 5)
///
/// 교체 대상
///   ZIP 안의 모든 파일을 같은 상대 경로로 설치 폴더에 교체한다(하위 폴더 포함).
///   ZIP 루트에 update.manifest.json 이 있으면 다음 규칙을 추가로 적용한다.
///   {
///     "preserve": ["config\\server.ini", "*.user.ini"],   // 이미 있으면 덮어쓰지 않음(없으면 설치)
///     "delete":   ["old\\legacy.dll"]                     // 설치 폴더에서 삭제
///   }
///   - 경로는 설치 폴더 기준 상대 경로, '/' 와 '\' 모두 허용
///   - preserve 는 와일드카드(* ?) 사용 가능, delete 는 정확한 경로만 허용
///   - backup\, updates\, --database 파일, 실행 중인 updater 자신은 교체하지 않는다.
///
/// 변경 내역 (원본 대비)
///   1. EXE 뿐 아니라 DLL, 설정 파일 등 ZIP 의 모든 파일을 교체, manifest 로 보존/삭제 지정
///   2. 교체/삭제한 파일을 모두 백업하고, 실패 시 역순으로 복원(새로 생긴 파일은 삭제)
///   3. 모든 파일을 먼저 .new 로 복사한 뒤 교체해 교체 구간을 최소화
///   4. 백업 정리를 폴더 생성 시각 기준으로 정렬 (버전 문자열 정렬 오류 수정)
///   5. 잠긴 파일 복사/교체 재시도, 롤백 중 예외가 원래 오류를 덮지 않도록 분리
///   6. 롤백 후 새 EXE 를 다시 실행하는 문제 수정
///   7. SQLite -wal / -shm 파일 함께 백업/복원
///   8. --version 값 정리, ZIP 항목 경로 검사 (경로 조작 / Zip Slip 방지)
///   9. OpenProcess 실패 시 권한 문제를 "이미 종료"로 오인하지 않음
///  10. 인수 검증 실패도 로그에 기록 (설치 폴더 또는 %TEMP%)

interface

type
  TUpdaterLog = reference to procedure(const Text: string);

/// 명령줄 인수로 업데이트를 수행한다.
/// 성공하면 True. 실패하면 이전 버전 복구를 시도한 뒤 False 와 사유를 돌려준다.
/// OnLog 는 호출한 스레드에서 실행된다(UI 라면 호출 측에서 스레드 전환).
function RunUpdater(const OnLog: TUpdaterLog; out ErrorMessage: string): Boolean;

implementation

uses
  Winapi.Windows,
  System.SysUtils,
  System.Classes,
  System.Types,
  System.IOUtils,
  System.DateUtils,
  System.Hash,
  System.Zip,
  System.JSON,
  System.Masks,
  System.Net.HttpClient,
  System.Generics.Collections,
  System.Generics.Defaults;

const
  DEFAULT_EXE_NAME        = 'OozyAttendanceServer.exe';
  MANIFEST_NAME           = 'update.manifest.json';
  DEFAULT_KEEP_BACKUPS    = 5;
  PROCESS_EXIT_TIMEOUT_MS = 120000;
  HEALTH_RETRY_COUNT      = 30;
  STARTUP_CHECK_MS        = 3000;
  RETRY_COUNT             = 20;
  RETRY_DELAY_MS          = 500;
  NEW_SUFFIX              = '.new';
  DB_SIDE_EXTS: array[0..1] of string = ('-wal', '-shm');

type
  TFileAction = (
    faReplace,      // 있으면 덮어쓰고, 없으면 설치
    faInstallOnly,  // preserve 대상인데 아직 없는 파일 -> 설치
    faDelete        // manifest delete 대상
  );

  TFileEntry = record
    RelPath: string;   // 설치 폴더 기준 상대 경로 (로그용)
    Source: string;    // staging 파일 (삭제는 '')
    Dest: string;      // 설치 폴더의 전체 경로
    Action: TFileAction;
    Backup: string;    // 기존 파일 백업 경로, 기존 파일이 없으면 ''
    Applied: Boolean;  // 실제로 교체/삭제했는지 (롤백 대상)
  end;

  TUpdateJob = record
    ParentPID: Cardinal;
    PackageFile: string;
    ChecksumFile: string;
    TargetDir: string;          // 끝에 '\' 포함
    ExeName: string;            // ZIP 루트의 실행 파일 이름
    RestartFile: string;        // 설치 폴더의 실행 파일 이름
    DatabaseFile: string;
    Version: string;            // 정리된 값
    HealthUrl: string;
    StartHttpServer: Boolean;
    KeepBackups: Integer;
    // 실행 중 결정되는 값
    InstalledFile: string;
    StagingDir: string;         // 끝에 '\' 포함
    BackupDir: string;
    BackupDatabaseFile: string; // 백업이 없으면 ''
    Files: TArray<TFileEntry>;
  end;

var
  GOnLog: TUpdaterLog;
  GLogFileName: string;
  // 교체 "전" 실패 시 기존 서버를 다시 띄우기 위한 정보
  GRecoverEnabled: Boolean;
  GRecoverExecutable: string;
  GRecoverWorkDir: string;
  GRecoverStartHttp: Boolean;

{ ---------------------------------------------------------------------------
  로그
  --------------------------------------------------------------------------- }

procedure Log(const Text: string);
var
  FileName: string;
begin
  if Assigned(GOnLog) then
    try
      GOnLog(Text);
    except
      // 화면 표시 실패가 업데이트를 막아서는 안 된다.
    end;

  FileName := GLogFileName;
  if FileName = '' then
    FileName := TPath.Combine(TPath.GetTempPath, 'JHAppUpdater.log');
  try
    TFile.AppendAllText(FileName,
      FormatDateTime('yyyy-mm-dd hh:nn:ss', Now) + '  ' + Text + sLineBreak,
      TEncoding.UTF8);
  except
    // 로그 기록 실패만으로 업데이트가 실패해서는 안 된다.
  end;
end;

{ ---------------------------------------------------------------------------
  인수 처리
  --------------------------------------------------------------------------- }

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

procedure Require(Condition: Boolean; const Msg: string);
begin
  if not Condition then
    raise Exception.Create('업데이트 실행 인수 오류: ' + Msg);
end;

/// 경로 구분자, 드라이브, '..' 가 없는 순수 파일 이름인지 확인
function IsPlainFileName(const Name: string): Boolean;
begin
  Result := (Name <> '') and (Name <> '.') and (Name <> '..') and
    (ExtractFileName(Name) = Name) and (Pos(':', Name) = 0) and
    (Pos('/', Name) = 0) and TPath.HasValidFileNameChars(Name, False);
end;

/// 폴더 이름에 쓸 수 있도록 버전 문자열 정리 (경로 조작 방지)
function SafeVersion(const Value: string): string;
var
  C: Char;
begin
  Result := '';
  for C in Value do
    if CharInSet(C, ['0'..'9', 'A'..'Z', 'a'..'z', '.', '-', '_']) then
      Result := Result + C;
  while (Result <> '') and (Result[1] = '.') do
    Delete(Result, 1, 1);
  if Result = '' then
    Result := 'unknown';
end;

procedure ParseArguments(out Job: TUpdateJob);
var
  RawTarget: string;
begin
  Job := Default(TUpdateJob);

  // 로그 위치를 가능한 한 먼저 정해서 인수 오류도 설치 폴더에 기록한다.
  RawTarget := ArgumentValue('--target');
  if (RawTarget <> '') and TPath.IsPathRooted(RawTarget) and
    TDirectory.Exists(RawTarget) then
  begin
    Job.TargetDir := IncludeTrailingPathDelimiter(TPath.GetFullPath(RawTarget));
    try
      TDirectory.CreateDirectory(Job.TargetDir + 'updates');
      GLogFileName := Job.TargetDir + 'updates\updater.log';
    except
      // 폴더 생성 실패 시 %TEMP% 로그 사용
    end;
  end;

  Log('updater 시작, 명령줄: ' + string(CmdLine));

  Job.ParentPID := Cardinal(StrToIntDef(ArgumentValue('--pid'), 0));
  Job.PackageFile := ArgumentValue('--package');
  Job.ChecksumFile := ArgumentValue('--checksum');
  Job.ExeName := ArgumentValue('--exe');
  Job.RestartFile := ArgumentValue('--restart');
  Job.DatabaseFile := ArgumentValue('--database');
  Job.Version := SafeVersion(ArgumentValue('--version'));
  Job.HealthUrl := ArgumentValue('--health-url');
  Job.StartHttpServer := HasArgument('--start-server');
  Job.KeepBackups := StrToIntDef(ArgumentValue('--keep-backups'),
    DEFAULT_KEEP_BACKUPS);
  if Job.KeepBackups < 1 then
    Job.KeepBackups := 1;

  if Job.ExeName = '' then
    Job.ExeName := DEFAULT_EXE_NAME;
  if Job.RestartFile = '' then
    Job.RestartFile := Job.ExeName;

  Require(Job.ParentPID <> 0, '--pid 가 없거나 숫자가 아닙니다.');
  Require(FileExists(Job.PackageFile), '--package 파일이 없습니다: ' + Job.PackageFile);
  Require(FileExists(Job.ChecksumFile), '--checksum 파일이 없습니다: ' + Job.ChecksumFile);
  Require(Job.TargetDir <> '', '--target 은 존재하는 절대 경로여야 합니다: ' + RawTarget);
  Require(IsPlainFileName(Job.ExeName), '--exe 는 경로 없는 파일 이름이어야 합니다: ' + Job.ExeName);
  Require(IsPlainFileName(Job.RestartFile), '--restart 는 경로 없는 파일 이름이어야 합니다: ' + Job.RestartFile);
  Require(not Job.StartHttpServer or (Job.HealthUrl <> ''),
    '--start-server 사용 시 --health-url 이 필요합니다.');

  if Job.DatabaseFile <> '' then
  begin
    if not TPath.IsPathRooted(Job.DatabaseFile) then
      Job.DatabaseFile := TPath.Combine(Job.TargetDir, Job.DatabaseFile);
    Job.DatabaseFile := TPath.GetFullPath(Job.DatabaseFile);
  end;

  Job.InstalledFile := Job.TargetDir + Job.RestartFile;
end;

{ ---------------------------------------------------------------------------
  파일 유틸리티
  --------------------------------------------------------------------------- }

/// 방금 종료된 프로세스가 파일을 잠깐 잡고 있을 수 있으므로 재시도한다.
procedure CopyWithRetry(const Source, Dest: string);
var
  I: Integer;
begin
  for I := 1 to RETRY_COUNT do
    try
      TFile.Copy(Source, Dest, True);
      Exit;
    except
      if I = RETRY_COUNT then
        raise;
      Sleep(RETRY_DELAY_MS);
    end;
end;

/// 같은 볼륨 안에서 원자적으로 교체 (재시도 포함)
procedure ReplaceWithRetry(const Source, Dest: string);
var
  I: Integer;
begin
  for I := 1 to RETRY_COUNT do
  begin
    if MoveFileEx(PChar(Source), PChar(Dest),
      MOVEFILE_REPLACE_EXISTING or MOVEFILE_WRITE_THROUGH) then
      Exit;
    if I = RETRY_COUNT then
      RaiseLastOSError;
    Sleep(RETRY_DELAY_MS);
  end;
end;

procedure DeleteFileWithRetry(const FileName: string);
var
  I: Integer;
begin
  for I := 1 to RETRY_COUNT do
  begin
    if not FileExists(FileName) or DeleteFile(FileName) then
      Exit;
    if I = RETRY_COUNT then
      RaiseLastOSError;
    Sleep(RETRY_DELAY_MS);
  end;
end;

/// Dest 가 들어갈 폴더를 만든 뒤 복사
procedure CopyCreatingDirs(const Source, Dest: string);
begin
  TDirectory.CreateDirectory(ExtractFileDir(Dest));
  CopyWithRetry(Source, Dest);
end;

function Sha256File(const FileName: string): string;
begin
  Result := LowerCase(THashSHA2.GetHashStringFromFile(FileName,
    THashSHA2.TSHA2Version.SHA256));
end;

/// UTF-8 (BOM 유무 무관) 텍스트 읽기
function ReadUtf8Text(const FileName: string): string;
begin
  Result := TEncoding.UTF8.GetString(TFile.ReadAllBytes(FileName));
  if (Result <> '') and (Result[1] = #$FEFF) then
    Delete(Result, 1, 1);
end;

/// 파일에서 64자리 16진수 묶음을 찾는다.
/// "hash", "hash  file.zip", "SHA256 (file.zip) = hash" 형식 모두 허용.
function ExpectedChecksum(const FileName: string): string;
var
  Text, Run: string;
  I: Integer;
begin
  Text := ReadUtf8Text(FileName) + ' ';
  Run := '';
  for I := 1 to Length(Text) do
    if CharInSet(Text[I], ['0'..'9', 'a'..'f', 'A'..'F']) then
      Run := Run + LowerCase(Text[I])
    else
    begin
      if Length(Run) = 64 then
        Exit(Run);
      Run := '';
    end;
  raise Exception.Create('SHA-256 파일에서 64자리 해시를 찾지 못했습니다.');
end;

/// FullPath 가 Root 폴더 안에 있는지 (Root 는 끝에 '\' 포함)
function IsInside(const FullPath, Root: string): Boolean;
begin
  Result := (Length(FullPath) > Length(Root)) and
    SameText(Copy(FullPath, 1, Length(Root)), Root);
end;

/// ZIP 항목이 대상 폴더 밖으로 나가지 않는지 확인한 뒤 압축 해제 (Zip Slip 방지)
procedure ExtractZipSafely(const ZipFileName, DestDir: string);
var
  Zip: TZipFile;
  I: Integer;
  Root, EntryName: string;
begin
  Root := IncludeTrailingPathDelimiter(TPath.GetFullPath(DestDir));
  Zip := TZipFile.Create;
  try
    Zip.Open(ZipFileName, zmRead);
    for I := 0 to Zip.FileCount - 1 do
    begin
      EntryName := StringReplace(Zip.FileNames[I], '/', '\', [rfReplaceAll]);
      if (EntryName = '') or (EntryName[1] = '\') or (Pos(':', EntryName) > 0) or
        not IsInside(TPath.GetFullPath(Root + EntryName), Root) then
        raise Exception.Create('ZIP 항목 경로가 올바르지 않습니다: ' + Zip.FileNames[I]);
    end;
    for I := 0 to Zip.FileCount - 1 do
      Zip.Extract(I, Root, True);
    Zip.Close;
  finally
    Zip.Free;
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
    // 이름(버전 문자열)이 아니라 생성 시각 기준으로 오래된 순서 정렬
    TArray.Sort<string>(Dirs, TComparer<string>.Construct(
      function(const L, R: string): Integer
      begin
        Result := CompareDateTime(TDirectory.GetCreationTime(L),
          TDirectory.GetCreationTime(R));
      end));
    for I := 0 to Length(Dirs) - 1 - Keep do
    begin
      TDirectory.Delete(Dirs[I], True);
      Log('오래된 백업 삭제: ' + Dirs[I]);
    end;
  except
    on E: Exception do
      Log('백업 정리 실패(무시): ' + E.Message);
  end;
end;

{ ---------------------------------------------------------------------------
  업데이트 파일 목록 (manifest)
  --------------------------------------------------------------------------- }

procedure ReadStringArray(Obj: TJSONObject; const Name: string; List: TStrings);
var
  V, Item: TJSONValue;
  I: Integer;
begin
  V := Obj.GetValue(Name);
  if V = nil then
    Exit;
  if not (V is TJSONArray) then
    raise Exception.CreateFmt('%s 의 "%s" 는 문자열 배열이어야 합니다.',
      [MANIFEST_NAME, Name]);
  for I := 0 to TJSONArray(V).Count - 1 do
  begin
    Item := TJSONArray(V).Items[I];
    if not (Item is TJSONString) then
      raise Exception.CreateFmt('%s 의 "%s" 에 문자열이 아닌 값이 있습니다.',
        [MANIFEST_NAME, Name]);
    List.Add(StringReplace(Trim(TJSONString(Item).Value), '/', '\', [rfReplaceAll]));
  end;
end;

procedure ReadManifest(const FileName: string; Preserve, DeleteList: TStrings);
var
  Value: TJSONValue;
begin
  Value := TJSONObject.ParseJSONValue(ReadUtf8Text(FileName));
  if not (Value is TJSONObject) then
  begin
    Value.Free;
    raise Exception.Create(MANIFEST_NAME + ' 형식이 올바르지 않습니다.');
  end;
  try
    ReadStringArray(TJSONObject(Value), 'preserve', Preserve);
    ReadStringArray(TJSONObject(Value), 'delete', DeleteList);
  finally
    Value.Free;
  end;
end;

function MatchesAny(const RelPath: string; Masks: TStrings): Boolean;
var
  Mask: string;
begin
  Result := False;
  for Mask in Masks do
    if (Mask <> '') and MatchesMask(RelPath, Mask) then
      Exit(True);
end;

/// 상대 경로를 검사해 설치 폴더의 전체 경로를 돌려준다.
/// 설치 폴더 밖, backup\ / updates\ 폴더, DB 파일은 거부한다.
function ResolveDest(const Job: TUpdateJob; const RelPath: string): string;
var
  I: Integer;
begin
  if (RelPath = '') or TPath.IsPathRooted(RelPath) or (Pos(':', RelPath) > 0) then
    raise Exception.Create('업데이트 파일 경로가 올바르지 않습니다: ' + RelPath);

  Result := TPath.GetFullPath(Job.TargetDir + RelPath);
  if not IsInside(Result, Job.TargetDir) then
    raise Exception.Create('설치 폴더 밖을 가리키는 경로입니다: ' + RelPath);
  if IsInside(Result, Job.TargetDir + 'backup\') or
    IsInside(Result, Job.TargetDir + 'updates\') then
    raise Exception.Create('backup\, updates\ 폴더는 업데이트할 수 없습니다: ' + RelPath);

  if Job.DatabaseFile <> '' then
  begin
    if SameText(Result, Job.DatabaseFile) then
      raise Exception.Create('DB 파일은 패키지로 교체할 수 없습니다: ' + RelPath);
    for I := Low(DB_SIDE_EXTS) to High(DB_SIDE_EXTS) do
      if SameText(Result, Job.DatabaseFile + DB_SIDE_EXTS[I]) then
        raise Exception.Create('DB 파일은 패키지로 교체할 수 없습니다: ' + RelPath);
  end;
end;

procedure AddEntry(var Job: TUpdateJob; const RelPath, Source, Dest: string;
  Action: TFileAction);
var
  Entry: TFileEntry;
begin
  Entry := Default(TFileEntry);
  Entry.RelPath := RelPath;
  Entry.Source := Source;
  Entry.Dest := Dest;
  Entry.Action := Action;
  Job.Files := Job.Files + [Entry];
end;

procedure BuildFileList(var Job: TUpdateJob);
var
  Preserve, DeleteList: TStringList;
  StagedFiles: TStringDynArray;
  StagedFile, RelPath, Dest, SelfPath: string;
  HasExe: Boolean;
  Action: TFileAction;
begin
  SetLength(Job.Files, 0);
  SelfPath := TPath.GetFullPath(ParamStr(0));
  HasExe := False;

  Preserve := TStringList.Create;
  DeleteList := TStringList.Create;
  try
    if FileExists(Job.StagingDir + MANIFEST_NAME) then
    begin
      ReadManifest(Job.StagingDir + MANIFEST_NAME, Preserve, DeleteList);
      Log(Format('manifest 적용: preserve %d개, delete %d개',
        [Preserve.Count, DeleteList.Count]));
    end;

    // 1. ZIP 의 모든 파일
    StagedFiles := TDirectory.GetFiles(Job.StagingDir, '*',
      TSearchOption.soAllDirectories);
    for StagedFile in StagedFiles do
    begin
      RelPath := Copy(StagedFile, Length(Job.StagingDir) + 1, MaxInt);
      if SameText(RelPath, MANIFEST_NAME) then
        Continue;

      // 서버 실행 파일은 --restart 이름으로 설치
      if SameText(RelPath, Job.ExeName) then
      begin
        Dest := Job.InstalledFile;
        HasExe := True;
      end
      else
        Dest := ResolveDest(Job, RelPath);

      if SameText(Dest, SelfPath) then
      begin
        Log('실행 중인 updater 자신은 교체하지 않습니다: ' + RelPath);
        Continue;
      end;

      Action := faReplace;
      if MatchesAny(RelPath, Preserve) then
      begin
        if FileExists(Dest) then
        begin
          Log('기존 설정 유지: ' + RelPath);
          Continue;
        end;
        Action := faInstallOnly;
      end;
      AddEntry(Job, RelPath, StagedFile, Dest, Action);
    end;

    if not HasExe then
      raise Exception.Create('업데이트 ZIP 루트에 실행 파일이 없습니다: ' + Job.ExeName);

    // 2. 삭제 대상 (와일드카드 불가)
    for RelPath in DeleteList do
    begin
      if RelPath = '' then
        Continue;
      if (Pos('*', RelPath) > 0) or (Pos('?', RelPath) > 0) then
        raise Exception.Create('delete 에는 와일드카드를 쓸 수 없습니다: ' + RelPath);
      Dest := ResolveDest(Job, RelPath);
      if SameText(Dest, Job.InstalledFile) or SameText(Dest, SelfPath) then
        raise Exception.Create('실행 파일은 delete 대상이 될 수 없습니다: ' + RelPath);
      if FileExists(Dest) then
        AddEntry(Job, RelPath, '', Dest, faDelete);
    end;
  finally
    Preserve.Free;
    DeleteList.Free;
  end;

  Log(Format('업데이트 대상 %d개 파일', [Length(Job.Files)]));
end;

{ ---------------------------------------------------------------------------
  백업 / 적용
  --------------------------------------------------------------------------- }

procedure BackupDatabase(var Job: TUpdateJob);
var
  I: Integer;
begin
  Job.BackupDatabaseFile := '';
  if (Job.DatabaseFile = '') or not FileExists(Job.DatabaseFile) then
    Exit;
  Job.BackupDatabaseFile :=
    TPath.Combine(Job.BackupDir, ExtractFileName(Job.DatabaseFile));
  CopyWithRetry(Job.DatabaseFile, Job.BackupDatabaseFile);
  for I := Low(DB_SIDE_EXTS) to High(DB_SIDE_EXTS) do
    if FileExists(Job.DatabaseFile + DB_SIDE_EXTS[I]) then
      CopyWithRetry(Job.DatabaseFile + DB_SIDE_EXTS[I],
        Job.BackupDatabaseFile + DB_SIDE_EXTS[I]);
end;

procedure RestoreDatabase(const Job: TUpdateJob);
var
  I: Integer;
begin
  CopyWithRetry(Job.BackupDatabaseFile, Job.DatabaseFile);
  for I := Low(DB_SIDE_EXTS) to High(DB_SIDE_EXTS) do
    if FileExists(Job.BackupDatabaseFile + DB_SIDE_EXTS[I]) then
      CopyWithRetry(Job.BackupDatabaseFile + DB_SIDE_EXTS[I],
        Job.DatabaseFile + DB_SIDE_EXTS[I])
    else
      DeleteFileWithRetry(Job.DatabaseFile + DB_SIDE_EXTS[I]);
end;

/// 교체/삭제할 기존 파일을 backup\<폴더>\files\<상대경로> 로 복사
procedure BackupFiles(var Job: TUpdateJob);
var
  I: Integer;
  Count: Integer;
begin
  Count := 0;
  for I := 0 to High(Job.Files) do
  begin
    Job.Files[I].Backup := '';
    if FileExists(Job.Files[I].Dest) then
    begin
      Job.Files[I].Backup := TPath.Combine(Job.BackupDir,
        'files\' + Copy(Job.Files[I].Dest, Length(Job.TargetDir) + 1, MaxInt));
      CopyCreatingDirs(Job.Files[I].Dest, Job.Files[I].Backup);
      Inc(Count);
    end;
  end;
  Log(Format('기존 파일 %d개 백업', [Count]));
end;

/// 1단계: 모든 새 파일을 설치 폴더에 <이름>.new 로 복사 (이 단계 실패는 원본에 영향 없음)
procedure PrepareFiles(const Job: TUpdateJob);
var
  Entry: TFileEntry;
begin
  for Entry in Job.Files do
    if Entry.Action <> faDelete then
      CopyCreatingDirs(Entry.Source, Entry.Dest + NEW_SUFFIX);
end;

/// 2단계: .new 를 원자적으로 교체하고 삭제 대상을 지운다.
procedure ApplyFiles(var Job: TUpdateJob);
var
  I: Integer;
begin
  for I := 0 to High(Job.Files) do
  begin
    if Job.Files[I].Action = faDelete then
    begin
      DeleteFileWithRetry(Job.Files[I].Dest);
      Job.Files[I].Applied := True;
      Log('삭제: ' + Job.Files[I].RelPath);
    end
    else
    begin
      ReplaceWithRetry(Job.Files[I].Dest + NEW_SUFFIX, Job.Files[I].Dest);
      Job.Files[I].Applied := True;
      if Job.Files[I].Backup <> '' then
        Log('교체: ' + Job.Files[I].RelPath)
      else
        Log('추가: ' + Job.Files[I].RelPath);
    end;
  end;
end;

{ ---------------------------------------------------------------------------
  프로세스
  --------------------------------------------------------------------------- }

procedure WaitForProcessExit(ProcessID: Cardinal);
var
  ProcessHandle: THandle;
  Err, WaitResult: DWORD;
begin
  ProcessHandle := OpenProcess(SYNCHRONIZE, False, ProcessID);
  if ProcessHandle = 0 then
  begin
    Err := GetLastError;
    // 존재하지 않는 PID 는 ERROR_INVALID_PARAMETER
    if Err = ERROR_INVALID_PARAMETER then
    begin
      Log(Format('서버 프로세스(PID=%d)가 이미 종료되었습니다.', [ProcessID]));
      Exit;
    end;
    raise Exception.CreateFmt('서버 프로세스(PID=%d)를 열 수 없습니다: %s',
      [ProcessID, SysErrorMessage(Err)]);
  end;
  try
    WaitResult := WaitForSingleObject(ProcessHandle, PROCESS_EXIT_TIMEOUT_MS);
    if WaitResult <> WAIT_OBJECT_0 then
      raise Exception.Create('서버 프로그램이 제한 시간 안에 종료되지 않았습니다.');
  finally
    CloseHandle(ProcessHandle);
  end;
end;

function StartServer(const FileName, WorkingDirectory: string;
  StartHttpServer: Boolean; out ProcessHandle: THandle): Boolean;
var
  StartupInfo: TStartupInfo;
  ProcessInfo: TProcessInformation;
  CommandLine: string;
begin
  CommandLine := '"' + FileName + '"';
  if StartHttpServer then
    CommandLine := CommandLine + ' --start-server';
  UniqueString(CommandLine); // CreateProcessW 는 명령줄 버퍼를 수정할 수 있다.

  FillChar(StartupInfo, SizeOf(StartupInfo), 0);
  StartupInfo.cb := SizeOf(StartupInfo);
  FillChar(ProcessInfo, SizeOf(ProcessInfo), 0);

  Result := CreateProcess(nil, PChar(CommandLine), nil, nil, False, 0, nil,
    PChar(WorkingDirectory), StartupInfo, ProcessInfo);
  if Result then
  begin
    CloseHandle(ProcessInfo.hThread);
    ProcessHandle := ProcessInfo.hProcess;
  end
  else
    ProcessHandle := 0;
end;

function StillRunning(ProcessHandle: THandle): Boolean;
var
  ExitCode: Cardinal;
begin
  Result := GetExitCodeProcess(ProcessHandle, ExitCode) and
    (ExitCode = STILL_ACTIVE);
end;

procedure StopProcess(var ProcessHandle: THandle);
begin
  if ProcessHandle = 0 then
    Exit;
  try
    if StillRunning(ProcessHandle) then
    begin
      TerminateProcess(ProcessHandle, 2);
      WaitForSingleObject(ProcessHandle, 10000);
    end;
  finally
    CloseHandle(ProcessHandle);
    ProcessHandle := 0;
  end;
end;

function WaitForHealth(const Url: string; ProcessHandle: THandle): Boolean;
var
  Client: THTTPClient;
  I: Integer;
begin
  Result := False;
  Client := THTTPClient.Create;
  try
    Client.ConnectionTimeout := 1000;
    Client.ResponseTimeout := 1500;
    for I := 1 to HEALTH_RETRY_COUNT do
    begin
      if not StillRunning(ProcessHandle) then
        Exit(False);
      try
        if Client.Get(Url).StatusCode = 200 then
          Exit(True);
      except
        // 서버가 아직 시작 중일 수 있다.
      end;
      Sleep(1000);
    end;
  finally
    Client.Free;
  end;
end;

/// 설치된 EXE 를 시작하고 상태를 확인한다.
function StartAndVerify(const Job: TUpdateJob; out ProcessHandle: THandle;
  out Reason: string): Boolean;
begin
  Result := False;
  Reason := '';
  if not StartServer(Job.InstalledFile, Job.TargetDir, Job.StartHttpServer,
    ProcessHandle) then
  begin
    Reason := '프로세스를 시작하지 못했습니다: ' + SysErrorMessage(GetLastError);
    Exit;
  end;

  if Job.StartHttpServer then
  begin
    if not WaitForHealth(Job.HealthUrl, ProcessHandle) then
    begin
      Reason := '/health 상태 확인이 실패했습니다.';
      Exit;
    end;
  end
  else
  begin
    Sleep(STARTUP_CHECK_MS); // HTTP 검증이 없으면 즉시 종료하지 않는지만 확인
    if not StillRunning(ProcessHandle) then
    begin
      Reason := '시작 직후 종료되었습니다.';
      Exit;
    end;
  end;
  Result := True;
end;

{ ---------------------------------------------------------------------------
  롤백
  --------------------------------------------------------------------------- }

/// 교체 "후" 실패했을 때 적용한 파일을 역순으로 되돌리고 재시작한다.
/// 파일별 예외는 기록만 하고 계속 진행해 가능한 많은 파일을 복구한다.
function Rollback(const Job: TUpdateJob): Boolean;
var
  I: Integer;
  AllRestored: Boolean;
  ProcessHandle: THandle;
  Reason: string;
begin
  Result := False;
  AllRestored := True;

  Log('적용한 파일을 복구합니다...');
  for I := High(Job.Files) downto 0 do
  begin
    if not Job.Files[I].Applied then
      Continue;
    try
      if Job.Files[I].Backup <> '' then
        CopyCreatingDirs(Job.Files[I].Backup, Job.Files[I].Dest)  // 교체/삭제한 파일 복원
      else
        DeleteFileWithRetry(Job.Files[I].Dest);                    // 새로 추가된 파일 제거
    except
      on E: Exception do
      begin
        AllRestored := False;
        Log('파일 복구 실패: ' + Job.Files[I].RelPath + ' - ' + E.Message);
      end;
    end;
  end;

  // 새 버전이 DB 스키마를 바꿨을 수 있으므로 DB 도 함께 되돌린다.
  if Job.BackupDatabaseFile <> '' then
    try
      RestoreDatabase(Job);
      Log('DB를 백업본으로 복구했습니다.');
    except
      on E: Exception do
      begin
        AllRestored := False;
        Log('DB 복구 실패: ' + E.Message);
      end;
    end;

  if not FileExists(Job.InstalledFile) then
  begin
    Log('이전 실행 파일이 없어 재시작할 수 없습니다(최초 설치일 수 있음).');
    Exit;
  end;

  ProcessHandle := 0;
  try
    try
      if StartAndVerify(Job, ProcessHandle, Reason) then
      begin
        Log('이전 버전으로 복구하고 재시작했습니다.');
        Result := AllRestored;
      end
      else
        // 이전 버전이라도 실행 중이면 종료하지 않고 둔다.
        Log('이전 버전 재시작 확인 실패: ' + Reason);
    except
      on E: Exception do
        Log('이전 버전 재시작 중 오류: ' + E.Message);
    end;
  finally
    if ProcessHandle <> 0 then
      CloseHandle(ProcessHandle);
  end;
end;

{ ---------------------------------------------------------------------------
  정리 (원래 예외를 덮지 않도록 각 단계 개별 처리)
  --------------------------------------------------------------------------- }

procedure Cleanup(const Job: TUpdateJob; var NewProcess: THandle);
var
  Entry: TFileEntry;
begin
  if NewProcess <> 0 then
  begin
    CloseHandle(NewProcess);
    NewProcess := 0;
  end;

  for Entry in Job.Files do
    if (Entry.Action <> faDelete) and FileExists(Entry.Dest + NEW_SUFFIX) then
      try
        DeleteFile(Entry.Dest + NEW_SUFFIX);
      except
        on E: Exception do
          Log('임시 파일 삭제 실패(무시): ' + E.Message);
      end;

  try
    if (Job.StagingDir <> '') and TDirectory.Exists(Job.StagingDir) then
      TDirectory.Delete(ExcludeTrailingPathDelimiter(Job.StagingDir), True);
  except
    on E: Exception do
      Log('staging 폴더 삭제 실패(무시): ' + E.Message);
  end;
end;

{ ---------------------------------------------------------------------------
  본 절차
  --------------------------------------------------------------------------- }

procedure Run;
var
  Job: TUpdateJob;
  ExpectedHash, ActualHash, Reason: string;
  NewProcess: THandle;
  Replaced, Restored: Boolean;
begin
  ParseArguments(Job);

  Log('업데이트 시작: ' + Job.Version);
  Log('서버 프로그램이 종료되기를 기다립니다...');
  WaitForProcessExit(Job.ParentPID);

  // 여기부터 교체 전에 실패하면 기존 서버를 다시 띄운다.
  GRecoverExecutable := Job.InstalledFile;
  GRecoverWorkDir := Job.TargetDir;
  GRecoverStartHttp := Job.StartHttpServer;
  GRecoverEnabled := True;

  NewProcess := 0;
  Replaced := False;
  try
    try
      // 1. 무결성 검증
      ExpectedHash := ExpectedChecksum(Job.ChecksumFile);
      ActualHash := Sha256File(Job.PackageFile);
      if not SameText(ExpectedHash, ActualHash) then
        raise Exception.Create('업데이트 ZIP의 SHA-256 검증에 실패했습니다.');
      Log('SHA-256 검증 완료');

      // 2. 압축 해제
      Job.StagingDir := Job.TargetDir + 'updates\staging-' +
        IntToStr(GetCurrentProcessId) + '\';
      if TDirectory.Exists(Job.StagingDir) then
        TDirectory.Delete(ExcludeTrailingPathDelimiter(Job.StagingDir), True);
      TDirectory.CreateDirectory(Job.StagingDir);
      Log('업데이트 파일 압축을 해제합니다...');
      ExtractZipSafely(Job.PackageFile, Job.StagingDir);

      // 3. 교체 대상 목록
      BuildFileList(Job);

      // 4. 백업 (폴더 이름: 날짜시각_버전)
      Job.BackupDir := Job.TargetDir + 'backup\' +
        FormatDateTime('yyyymmdd-hhnnss', Now) + '_' + Job.Version;
      TDirectory.CreateDirectory(Job.BackupDir);
      BackupFiles(Job);
      BackupDatabase(Job);
      Log('백업 완료: ' + Job.BackupDir);

      // 5. 교체: 모두 .new 로 복사한 뒤 한꺼번에 교체
      PrepareFiles(Job);
      Replaced := True;   // 이 시점부터는 일부 파일이 바뀌었을 수 있으므로 롤백 대상
      ApplyFiles(Job);
      Log('파일 교체 완료');

      // 6. 새 버전 시작 및 상태 확인
      Log('새 버전을 시작했습니다. 상태를 확인합니다...');
      if not StartAndVerify(Job, NewProcess, Reason) then
        raise Exception.Create('새 버전 ' + Reason);

      Log('업데이트 완료: ' + Job.Version);
    except
      on E: Exception do
      begin
        StopProcess(NewProcess);

        // 교체 전 실패: 원본이 그대로이므로 RunUpdater 가 기존 서버를 재시작한다.
        if not Replaced then
          raise;

        // 교체 후 실패: 여기서 롤백. 새 EXE 를 다시 실행하지 않도록 플래그 해제.
        GRecoverEnabled := False;
        Log('업데이트 실패, 복구를 시작합니다: ' + E.Message);
        Restored := Rollback(Job);
        if Restored then
          raise Exception.Create(
            '업데이트를 적용하지 못해 이전 버전으로 복구했습니다: ' + E.Message)
        else
          raise Exception.Create(
            '업데이트 실패, 자동 복구가 완전하지 않습니다(수동 조치 필요). 백업 위치: ' +
            Job.BackupDir + ' / 원인: ' + E.Message);
      end;
    end;

    GRecoverEnabled := False;
    PruneBackups(Job.TargetDir + 'backup', Job.KeepBackups);
  finally
    Cleanup(Job, NewProcess);
  end;
end;

function RunUpdater(const OnLog: TUpdaterLog; out ErrorMessage: string): Boolean;
var
  RecoveryProcess: THandle;
begin
  GOnLog := OnLog;
  GLogFileName := '';
  GRecoverEnabled := False;
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

      if GRecoverEnabled and FileExists(GRecoverExecutable) then
      begin
        GRecoverEnabled := False;
        if StartServer(GRecoverExecutable, GRecoverWorkDir, GRecoverStartHttp,
          RecoveryProcess) then
        begin
          Log('업데이트 적용 전 오류로 기존 서버를 다시 시작했습니다.');
          CloseHandle(RecoveryProcess);
        end
        else
          Log('기존 서버 자동 재시작에도 실패했습니다: ' +
            SysErrorMessage(GetLastError));
      end;
    end;
  end;
  GOnLog := nil;
end;

end.
