using System;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Threading;

internal sealed class LockLease : IDisposable
{
    private readonly Mutex mutex;
    private bool held;

    private LockLease(Mutex value, bool acquired) { mutex = value; held = acquired; }

    internal static LockLease Acquire(string name, int waitMilliseconds)
    {
        var user = WindowsIdentity.GetCurrent().User;
        if (user == null) throw new InvalidOperationException("current user SID is unavailable");
        var security = new MutexSecurity();
        security.SetAccessRuleProtection(true, false);
        security.AddAccessRule(new MutexAccessRule(user, MutexRights.FullControl, AccessControlType.Allow));
        bool created;
        var mutex = new Mutex(false, "Global\\BankAgentSandbox_" + user.Value + "_" + name, out created, security);
        try
        {
            bool held;
            try { held = mutex.WaitOne(waitMilliseconds); }
            catch (AbandonedMutexException) { held = true; }
            if (!held) throw new InvalidOperationException("workspace is busy; retry after the active command completes");
            return new LockLease(mutex, true);
        }
        catch { mutex.Dispose(); throw; }
    }

    public void Dispose()
    {
        if (held) { mutex.ReleaseMutex(); held = false; }
        mutex.Dispose();
    }
}
