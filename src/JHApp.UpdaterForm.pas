unit JHApp.UpdaterForm;

/// updater GUI: 진행 상황을 보여 주고 결과(성공/실패)를 알린다. DFM 없이 코드로 구성한다.

interface

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  Vcl.Forms,
  Vcl.Controls,
  Vcl.StdCtrls,
  Vcl.ExtCtrls,
  Vcl.ComCtrls,
  Vcl.Graphics;

type
  TUpdaterForm = class(TForm)
  private
    fTitle: TLabel;
    fBar: TProgressBar;
    fMemo: TMemo;
    fClose: TButton;
    fTimer: TTimer;
    fLock: TCriticalSection;
    fPending: TStringList;  // 작업 스레드가 쌓고 타이머가 UI 스레드에서 비운다
    fRunning: Boolean;
    fDone: Boolean;
    fOk: Boolean;
    fError: string;
    fCloseCountdown: Integer;
    procedure Push(const Text: string);
    procedure Worker;
    procedure TimerTick(Sender: TObject);
    procedure CloseClick(Sender: TObject);
  protected
    procedure DoShow; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    function CloseQuery: Boolean; override;
  end;

var
  UpdaterForm: TUpdaterForm;

implementation

uses
  JHApp.UpdaterCore;

constructor TUpdaterForm.Create(AOwner: TComponent);
begin
  inherited CreateNew(AOwner); // DFM 리소스를 찾지 않는 생성자
  fLock := TCriticalSection.Create;
  fPending := TStringList.Create;
  Caption := 'Oozy 출퇴근 서버 업데이트';
  BorderStyle := bsDialog;
  Position := poScreenCenter;
  ClientWidth := 520;
  ClientHeight := 330;
  Font.Name := 'Malgun Gothic';
  Font.Size := 9;

  fTitle := TLabel.Create(Self);
  fTitle.Parent := Self;
  fTitle.SetBounds(16, 14, 488, 20);
  fTitle.Font.Style := [fsBold];
  fTitle.Font.Size := 11;
  fTitle.Caption := '업데이트를 준비하고 있습니다...';

  fBar := TProgressBar.Create(Self);
  fBar.Parent := Self;
  fBar.SetBounds(16, 44, 488, 18);
  fBar.Style := pbstMarquee;

  fMemo := TMemo.Create(Self);
  fMemo.Parent := Self;
  fMemo.SetBounds(16, 74, 488, 192);
  fMemo.ReadOnly := True;
  fMemo.ScrollBars := ssVertical;

  fClose := TButton.Create(Self);
  fClose.Parent := Self;
  fClose.SetBounds(404, 282, 100, 32);
  fClose.Caption := '닫기';
  fClose.Enabled := False;
  fClose.OnClick := CloseClick;

  fTimer := TTimer.Create(Self);
  fTimer.Interval := 200;
  fTimer.OnTimer := TimerTick;
  fTimer.Enabled := False;
end;

destructor TUpdaterForm.Destroy;
begin
  fPending.Free;
  fLock.Free;
  inherited;
end;

function TUpdaterForm.CloseQuery: Boolean;
begin
  // 교체 중에 창을 닫아도 작업은 계속되지만, 실수로 닫아 결과를 놓치지 않게 막는다
  Result := fDone and inherited CloseQuery;
end;

procedure TUpdaterForm.DoShow;
begin
  inherited;
  if fRunning or fDone then
    Exit;
  fRunning := True;
  fTimer.Enabled := True;
  TThread.CreateAnonymousThread(
    procedure
    begin
      Worker;
    end).Start;
end;

procedure TUpdaterForm.Push(const Text: string);
begin
  fLock.Enter;
  try
    fPending.Add(FormatDateTime('hh:nn:ss', Now) + '  ' + Text);
  finally
    fLock.Leave;
  end;
end;

procedure TUpdaterForm.Worker;
var
  Ok: Boolean;
  Err: string;
begin
  Ok := RunUpdater(
    procedure(const Text: string)
    begin
      Push(Text);
    end, Err);
  fLock.Enter;
  try
    fOk := Ok;
    fError := Err;
    fDone := True;
  finally
    fLock.Leave;
  end;
end;

procedure TUpdaterForm.TimerTick(Sender: TObject);
var
  Lines: TStringList;
  Done, Ok: Boolean;
  Err: string;
begin
  Lines := TStringList.Create;
  try
    fLock.Enter;
    try
      Lines.Assign(fPending);
      fPending.Clear;
      Done := fDone;
      Ok := fOk;
      Err := fError;
    finally
      fLock.Leave;
    end;
    if Lines.Count > 0 then
    begin
      fMemo.Lines.AddStrings(Lines);
      fTitle.Caption := Lines[Lines.Count - 1];
    end;
  finally
    Lines.Free;
  end;
  if not Done then
    Exit;
  if fCloseCountdown = 0 then
  begin
    fRunning := False;
    fBar.Style := pbstNormal;
    fBar.Position := 100;
    fClose.Enabled := True;
    if Ok then
    begin
      fTitle.Font.Color := clGreen;
      fTitle.Caption := '업데이트가 완료되었습니다. 서버가 다시 시작됩니다.';
      fCloseCountdown := 15; // 약 3초 뒤 자동 종료
    end
    else
    begin
      fTitle.Font.Color := clMaroon;
      fTitle.Caption := '업데이트에 실패했습니다.';
      fMemo.Lines.Add('');
      fMemo.Lines.Add('사유: ' + Err);
      fMemo.Lines.Add('로그: updates\updater.log');
      fCloseCountdown := -1; // 실패는 자동으로 닫지 않는다
    end;
  end
  else if fCloseCountdown > 0 then
  begin
    Dec(fCloseCountdown);
    if fCloseCountdown = 0 then
    begin
      fCloseCountdown := -1;
      Close;
    end;
  end;
end;

procedure TUpdaterForm.CloseClick(Sender: TObject);
begin
  Close;
end;

end.
