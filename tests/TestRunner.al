namespace DefaultPublisher.CICDTestApp.Tests;

codeunit 50201 "Sample Test Runner"
{
    Subtype = TestRunner;

    trigger OnRun()
    begin
        Codeunit.Run(50200);
    end;
}
