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

        [Theory]
        [InlineData(true)]
        [InlineData(false)]
        public void Lookup_StoredKey_ReturnsTheCachedClassificationWithoutAWalk(bool stored)
        {
            var cache = new OwnClassificationCache(maxWalks: 10);
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
        public void Lookup_WalkBudgetSpent_CachedKeysStillAnswer()
        {
            var cache = new OwnClassificationCache(maxWalks: 1);
            bool own;
            cache.Lookup("A", out own);
            cache.Store("A", true);
            cache.Lookup("B", out own);

            Assert.Equal(OwnLookup.Cached, cache.Lookup("A", out own));
            Assert.True(own);
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
            var cache = new OwnClassificationCache(maxWalks: 10);
            bool own;
            cache.Store("A", true);
            cache.Store("A", false);

            cache.Lookup("A", out own);

            Assert.True(own);
        }

        [Fact]
        public void LookupAndStore_NullKey_ActAsTheEmptyKey()
        {
            var cache = new OwnClassificationCache(maxWalks: 10);
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
        public void Constructor_NegativeWalks_Throws()
        {
            Assert.Throws<ArgumentOutOfRangeException>(() => new OwnClassificationCache(-1));
        }
    }
}
