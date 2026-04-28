import { useState, useEffect } from 'react'
import './App.css'

function App() {
  const [products, setProducts] = useState([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)
  const [cart, setCart] = useState([])
  const [isCartOpen, setIsCartOpen] = useState(false)

  useEffect(() => {
    fetch('http://localhost:3001/api/products')
      .then(res => {
        if (!res.ok) throw new Error('Network response was not ok')
        return res.json()
      })
      .then(data => {
        setProducts(data)
        setLoading(false)
      })
      .catch(err => {
        setError(err.message)
        setLoading(false)
      })
  }, [])

  const addToCart = (product) => {
    setCart(prev => {
      const existing = prev.find(item => item.id === product.id)
      if (existing) {
        return prev.map(item => item.id === product.id ? { ...item, quantity: item.quantity + 1 } : item)
      }
      return [...prev, { ...product, quantity: 1 }]
    })
  }

  const removeFromCart = (id) => {
    setCart(prev => prev.filter(item => item.id !== id))
  }

  const cartTotal = cart.reduce((sum, item) => sum + (item.price * item.quantity), 0)
  const cartCount = cart.reduce((sum, item) => sum + item.quantity, 0)

  return (
    <div className="app-container">
      {/* Navigation */}
      <nav className="navbar">
        <div className="nav-brand">
          <span className="brand-icon">⚡</span>
          <h1>AeroStore</h1>
        </div>
        <div className="nav-actions">
          <button className="cart-toggle" onClick={() => setIsCartOpen(true)}>
            🛒 Cart
            {cartCount > 0 && <span className="cart-badge">{cartCount}</span>}
          </button>
        </div>
      </nav>

      {/* Hero Section */}
      <header className="hero">
        <div className="hero-content">
          <h2>Next-Gen Tech Setup</h2>
          <p>Upgrade your workspace with our premium selection of electronics and accessories.</p>
          <button className="hero-cta" onClick={() => window.scrollTo({ top: window.innerHeight, behavior: 'smooth' })}>
            Shop Now
          </button>
        </div>
      </header>

      {/* Main Content */}
      <main className="main-content">
        <div className="section-header">
          <h2>Featured Products</h2>
          <div className="filter-pills">
            <span className="pill active">All</span>
            <span className="pill">Electronics</span>
            <span className="pill">Accessories</span>
          </div>
        </div>

        {loading && <div className="loader">Loading premium gear...</div>}
        {error && <div className="error-state">Failed to load store: {error}</div>}

        <div className="product-grid">
          {!loading && !error && products.map(product => (
            <div key={product.id} className="product-card">
              <div className="product-image-placeholder">
                <span className="category-tag">{product.category}</span>
              </div>
              <div className="product-info">
                <h3>{product.name}</h3>
                <div className="price-row">
                  <span className="price">${product.price.toFixed(2)}</span>
                  {product.stock < 50 && <span className="low-stock">Low Stock</span>}
                </div>
                <button className="add-button" onClick={() => addToCart(product)}>
                  Add to Cart
                </button>
              </div>
            </div>
          ))}
        </div>
      </main>

      {/* Cart Sidebar (Glassmorphism) */}
      <div className={`cart-overlay ${isCartOpen ? 'open' : ''}`} onClick={() => setIsCartOpen(false)}>
        <div className="cart-sidebar" onClick={e => e.stopPropagation()}>
          <div className="cart-header">
            <h2>Your Cart</h2>
            <button className="close-cart" onClick={() => setIsCartOpen(false)}>✕</button>
          </div>
          
          <div className="cart-items">
            {cart.length === 0 ? (
              <div className="empty-cart">Your cart is empty</div>
            ) : (
              cart.map(item => (
                <div key={item.id} className="cart-item">
                  <div className="cart-item-details">
                    <h4>{item.name}</h4>
                    <p>${item.price.toFixed(2)} x {item.quantity}</p>
                  </div>
                  <button className="remove-item" onClick={() => removeFromCart(item.id)}>🗑️</button>
                </div>
              ))
            )}
          </div>

          {cart.length > 0 && (
            <div className="cart-footer">
              <div className="cart-total">
                <span>Total:</span>
                <span>${cartTotal.toFixed(2)}</span>
              </div>
              <button className="checkout-btn">Checkout</button>
            </div>
          )}
        </div>
      </div>
    </div>
  )
}

export default App
