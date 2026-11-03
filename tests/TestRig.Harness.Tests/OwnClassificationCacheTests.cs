using System;
using TestRig.Harness.Logic;
using Xunit;

namespace TestRig.Harness.Tests
{
    public class OwnClassificationCacheTests
    {
        [Fact]
        public void Lookup_UnknownKey_AsksForAWalk()
        {
            var cache = new OwnClassificationCache(maxWalks: 10);
            bool own;

            Assert.Equal(OwnLookup.Walk, cache.Lookup("A", out own));
            Assert.False(own);
            Assert.Equal(1, cache.Walks);
        }

        [Fact]
        public void Lookup_StoredKeyWithinTheBudget_StillAsksForAWalk()
        {
            // F-S6-4: every exception is classified by its own walk until the budget is spent.
            var cache = new OwnClassificationCache(maxWalks: 10);
            bool own;
            cache.Lookup("A", out own);
            cache.Store("A", true);

            Assert.Equal(OwnLookup.Walk, cache.Lookup("A", out own));
            Assert.False(own);
            Assert.Equal(2, cache.Walks);
        }

        [Theory]
        [InlineData(true)]
        [InlineData(false)]
        public void Lookup_WalkBudgetSpent_StoredKeyReturnsTheCachedClassification(bool stored)
        {
            var cache = new OwnClassificationCache(maxWalks: 1);
            bool own;
            cache.Lookup("A", out own);
            cache.Store("A", stored);

            Assert.Equal(OwnLookup.Cached, cache.Lookup("A", out own));
            Assert.Equal(stored, own);
            Assert.Equal(1, cache.Walks);
        }

        [Fact]
        public void Lookup_WalkBudgetSpent_UnknownKeyIsUnknownAndNotOwn()
        {
            var cache = new OwnClassificationCache(maxWalks: 2);
            bool own;
            cache.Lookup("A", out own);
            cache.Store("A", true);
            cache.Lookup("B", out own);
            cache.Store("B", true);

            Assert.Equal(OwnLookup.Unknown, cache.Lookup("C", out own));
            Assert.False(own);
            Assert.Equal(2, cache.Walks);
        }

        [Fact]
        public void Lookup_ReservedButNotYetStored_CountsEveryWalkAgainstTheBudget()
        {
            // Two threads can miss the same key before either stores it: each walk is spent.
            var cache = new OwnClassificationCache(maxWalks: 2);
            bool own;

            Assert.Equal(OwnLookup.Walk, cache.Lookup("A", out own));
            Assert.Equal(OwnLookup.Walk, cache.Lookup("A", out own));
            Assert.Equal(OwnLookup.Unknown, cache.Lookup("A", out own));
            Assert.Equal(2, cache.Walks);
        }

        [Fact]
        public void Store_KeepsTheFirstClassification()
        {
            var cache = new OwnClassificationCache(maxWalks: 0);
            bool own;
            cache.Store("A", true);
            cache.Store("A", false);

            cache.Lookup("A", out own);

            Assert.True(own);
        }

        [Fact]
        public void LookupAndStore_NullKey_ActAsTheEmptyKey()
        {
            var cache = new OwnClassificationCache(maxWalks: 0);
            bool own;
            cache.Store(null, true);

            Assert.Equal(OwnLookup.Cached, cache.Lookup(string.Empty, out own));
            Assert.True(own);
        }

        [Fact]
        public void ZeroWalks_NeverWalks()
        {
            var cache = new OwnClassificationCache(maxWalks: 0);
            bool own;

            Assert.Equal(OwnLookup.Unknown, cache.Lookup("A", out own));
            Assert.Equal(0, cache.Walks);
        }

        [Fact]
        public void OwnExact_WithoutLookups_IsTrue()
        {
            Assert.True(new OwnClassificationCache(maxWalks: 0).OwnExact);
        }

        [Fact]
        public void OwnExact_EveryLookupWalked_StaysTrueEvenWithTheBudgetJustSpent()
        {
            var cache = new OwnClassificationCache(maxWalks: 2);
            bool own;
            cache.Lookup("A", out own);
            cache.Lookup("A", out own);

            Assert.Equal(2, cache.Walks);
            Assert.True(cache.OwnExact);
        }

        [Fact]
        public void OwnExact_CachedAnswerAfterTheBudget_IsFalse()
        {
            var cache = new OwnClassificationCache(maxWalks: 1);
            bool own;
            cache.Lookup("A", out own);
            cache.Store("A", true);

            cache.Lookup("A", out own);

            Assert.False(cache.OwnExact);
        }

        [Fact]
        public void OwnExact_UnknownAfterTheBudget_IsFalseAndStaysFalse()
        {
            var cache = new OwnClassificationCache(maxWalks: 0);
            bool own;

            cache.Lookup("A", out own);
            cache.Store("B", false);

            Assert.False(cache.OwnExact);
        }

        [Fact]
        public void MarkInexact_FailedWalkWithinTheBudget_TurnsOwnExactFalseAndKeepsTheBudget()
        {
            // A granted walk that could not classify counts as not own: "own" is no longer exact.
            var cache = new OwnClassificationCache(maxWalks: 2);
            bool own;
            cache.Lookup("A", out own);

            cache.MarkInexact();

            Assert.False(cache.OwnExact);
            Assert.Equal(1, cache.Walks);
            Assert.Equal(OwnLookup.Walk, cache.Lookup("A", out own));
            Assert.False(cache.OwnExact);
        }

        [Fact]
        public void Constructor_NegativeWalks_Throws()
        {
            Assert.Throws<ArgumentOutOfRangeException>(() => new OwnClassificationCache(-1));
        }
    }
}
