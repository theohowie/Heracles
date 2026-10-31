import React from 'react'
import ReactDOM from 'react-dom/client'
import App from './Landing.jsx'
import { MotionProvider } from './motion.jsx'
import './main.css'

ReactDOM.createRoot(document.getElementById('root')).render(
  <React.StrictMode>
    <MotionProvider>
      <App />
    </MotionProvider>
  </React.StrictMode>,
)
