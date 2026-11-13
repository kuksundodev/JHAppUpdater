program JHAppUpdaterGUI;

uses
  Vcl.Forms,
  JHApp.UpdaterCore in 'JHApp.UpdaterCore.pas',
  JHApp.UpdaterForm in 'JHApp.UpdaterForm.pas';

{$R *.res}

begin
  Application.Initialize;
  Application.MainFormOnTaskbar := True;
  Application.CreateForm(TUpdaterForm, UpdaterForm);
  Application.Run;
end.
