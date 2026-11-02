using TestRig.Harness.Logic;
using Xunit;

namespace TestRig.Harness.Tests
{
    public class AliveClockTests
    {
        [Fact]
        public void TryBeat_BeforeTheInterval_IsNotDue()
        {
            var clock = new AliveClock(10, 0);

            Assert.False(clock.TryBeat(0));
            Assert.False(clock.TryBeat(9.9));
        }

        [Fact]
        public void TryBeat_AtTheInterval_IsDue()
        {
            var clock = new AliveClock(10, 0);

            Assert.True(clock.TryBeat(10));
        }

        [Fact]
        public void TryBeat_FirstBeatIsOneIntervalAfterTheStart()
        {
            var clock = new AliveClock(10, 100);

            Assert.False(clock.TryBeat(109.9));
            Assert.True(clock.TryBeat(110));
        }

        [Fact]
        public void TryBeat_SecondCallInTheSameWindow_IsNotDue()
        {
            var clock = new AliveClock(10, 0);

            Assert.True(clock.TryBeat(10));
            Assert.False(clock.TryBeat(10));
            Assert.False(clock.TryBeat(19.9));
        }

        [Fact]
        public void TryBeat_NextWindow_IsDueAgain()
        {
            var clock = new AliveClock(10, 0);

            Assert.True(clock.TryBeat(10));
            Assert.True(clock.TryBeat(20));
        }

        [Fact]
        public void TryBeat_LateTick_BeatsOnceAndRestartsTheWindow()
        {
            var clock = new AliveClock(10, 0);

            Assert.True(clock.TryBeat(45));
            Assert.False(clock.TryBeat(50));
            Assert.True(clock.TryBeat(55));
        }

        [Fact]
        public void TryBeat_ClockGoingBackwards_IsNotDue()
        {
            var clock = new AliveClock(10, 0);
            Assert.True(clock.TryBeat(30));

            Assert.False(clock.TryBeat(5));
            Assert.True(clock.TryBeat(40));
        }

        [Fact]
        public void Constructor_NonPositiveInterval_Throws()
        {
            Assert.Throws<System.ArgumentOutOfRangeException>(() => new AliveClock(0, 0));
            Assert.Throws<System.ArgumentOutOfRangeException>(() => new AliveClock(-1, 0));
        }
    }
}
