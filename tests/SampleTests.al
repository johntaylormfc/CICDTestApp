namespace DefaultPublisher.CICDTestApp.Tests;

codeunit 50200 "Sample Tests"
{
    Subtype = Test;

    [Test]
    procedure HelloWorld_Passes();
    begin
        // Minimal passing test – will error if failing
        if 1 <> 1 then
            Error('Expected 1 = 1');
    end;
}
