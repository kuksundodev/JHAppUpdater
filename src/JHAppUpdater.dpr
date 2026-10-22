program JHAppUpdater;

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  JHApp.UpdaterCore in 'JHApp.UpdaterCore.pas';

var
  Err: string;

begin
  if not RunUpdater(nil, Err) then
  begin
    Writeln(ErrOutput, Err);
    Halt(1);
  end;
end.
