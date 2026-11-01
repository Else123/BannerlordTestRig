using System;
using System.Collections.Generic;
using System.IO;
using TestRig.Harness.Logic;
using Xunit;

namespace TestRig.Harness.Tests
{
    public class IoRetryTests
    {
        private readonly List<int> _sleeps = new List<int>();

        private void Sleep(int milliseconds)
        {
            _sleeps.Add(milliseconds);
        }

        [Fact]
        public void Run_Success_RunsOnceWithoutWaiting()
        {
            int calls = 0;

            IoRetry.Run(() => calls++, attempts: 4, delayMilliseconds: 75, sleep: Sleep);

            Assert.Equal(1, calls);
            Assert.Empty(_sleeps);
        }

        [Fact]
        public void Run_IOExceptionThenSuccess_RetriesAfterTheDelay()
        {
            int calls = 0;

            IoRetry.Run(
                () =>
                {
                    calls++;
                    if (calls < 3)
                    {
                        throw new IOException("locked");
                    }
                },
                attempts: 4,
                delayMilliseconds: 75,
                sleep: Sleep);

            Assert.Equal(3, calls);
            Assert.Equal(new[] { 75, 75 }, _sleeps);
        }

        [Fact]
        public void Run_IOExceptionOnEveryAttempt_RethrowsTheLastAfterAllAttempts()
        {
            int calls = 0;

            IOException thrown = Assert.Throws<IOException>(() => IoRetry.Run(
                () =>
                {
                    calls++;
                    throw new IOException("attempt " + calls);
                },
                attempts: 4,
                delayMilliseconds: 50,
                sleep: Sleep));

            Assert.Equal(4, calls);
            Assert.Equal("attempt 4", thrown.Message);
            Assert.Equal(new[] { 50, 50, 50 }, _sleeps);
        }

        [Fact]
        public void Run_IOExceptionSubclass_IsRetried()
        {
            int calls = 0;

            IoRetry.Run(
                () =>
                {
                    calls++;
                    if (calls == 1)
                    {
                        throw new FileNotFoundException("gone");
                    }
                },
                attempts: 3,
                delayMilliseconds: 50,
                sleep: Sleep);

            Assert.Equal(2, calls);
        }

        [Fact]
        public void Run_UnauthorizedAccessExceptionThenSuccess_IsRetried()
        {
            // Windows reports a pending-delete or scanner-held target as ERROR_ACCESS_DENIED.
            int calls = 0;

            IoRetry.Run(
                () =>
                {
                    calls++;
                    if (calls < 3)
                    {
                        throw new UnauthorizedAccessException("denied");
                    }
                },
                attempts: 4,
                delayMilliseconds: 75,
                sleep: Sleep);

            Assert.Equal(3, calls);
            Assert.Equal(new[] { 75, 75 }, _sleeps);
        }

        [Fact]
        public void Run_UnauthorizedAccessExceptionOnEveryAttempt_RethrowsAfterAllAttempts()
        {
            int calls = 0;

            Assert.Throws<UnauthorizedAccessException>(() => IoRetry.Run(
                () =>
                {
                    calls++;
                    throw new UnauthorizedAccessException("denied");
                },
                attempts: 3,
                delayMilliseconds: 50,
                sleep: Sleep));

            Assert.Equal(3, calls);
            Assert.Equal(new[] { 50, 50 }, _sleeps);
        }

        [Fact]
        public void Run_OtherException_PropagatesWithoutRetry()
        {
            int calls = 0;

            Assert.Throws<InvalidOperationException>(() => IoRetry.Run(
                () =>
                {
                    calls++;
                    throw new InvalidOperationException("broken");
                },
                attempts: 4,
                delayMilliseconds: 50,
                sleep: Sleep));

            Assert.Equal(1, calls);
            Assert.Empty(_sleeps);
        }

        [Fact]
        public void Run_InvalidArguments_Throw()
        {
            Assert.Throws<ArgumentNullException>(() => IoRetry.Run(null, 3, 50, Sleep));
            Assert.Throws<ArgumentNullException>(() => IoRetry.Run(() => { }, 3, 50, null));
            Assert.Throws<ArgumentOutOfRangeException>(() => IoRetry.Run(() => { }, 0, 50, Sleep));
            Assert.Throws<ArgumentOutOfRangeException>(() => IoRetry.Run(() => { }, 3, -1, Sleep));
        }
    }
}
