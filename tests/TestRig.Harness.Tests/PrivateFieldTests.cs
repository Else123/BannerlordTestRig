using TestRig.Harness.Logic;
using Xunit;

namespace TestRig.Harness.Tests
{
    public class PrivateFieldTests
    {
        private class Dummy
        {
            private bool _flag;
            private int _count;
            public bool Flag { get { return _flag; } }
            public int Count { get { return _count; } }
        }

        [Fact]
        public void SetBool_PrivateBoolField_SetsItAndReturnsTrue()
        {
            var target = new Dummy();

            bool ok = PrivateField.TrySetBool(target, "_flag", true);

            Assert.True(ok);
            Assert.True(target.Flag);
        }

        [Fact]
        public void SetBool_MissingField_ReturnsFalse()
        {
            Assert.False(PrivateField.TrySetBool(new Dummy(), "_nope", true));
        }

        [Fact]
        public void SetBool_FieldOfWrongType_ReturnsFalseAndLeavesItUntouched()
        {
            var target = new Dummy();

            Assert.False(PrivateField.TrySetBool(target, "_count", true));
            Assert.Equal(0, target.Count);
        }

        [Fact]
        public void SetBool_NullTarget_ReturnsFalse()
        {
            Assert.False(PrivateField.TrySetBool(null, "_flag", true));
        }
    }
}
